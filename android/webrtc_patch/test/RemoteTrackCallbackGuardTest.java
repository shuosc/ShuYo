package com.cloudwebrtc.webrtc;

import static org.junit.Assert.*;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.Test;

public class RemoteTrackCallbackGuardTest {
  @Test
  public void staleOptionalMetadataStillPublishesTheUsableTrack() {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    List<RuntimeException> failures = new ArrayList<>();
    List<Map<String, Object>> events = new ArrayList<>();
    Map<String, Object> event = new HashMap<>();
    event.put("track", "usable-video");
    guard.run(() -> {
      Object metadata = guard.optional(() -> {
        throw new IllegalStateException("RtpTransceiver has been disposed");
      }, failures::add);
      if (metadata != null) event.put("transceiver", metadata);
      events.add(event);
    }, failures::add);
    assertEquals(1, events.size());
    assertEquals("usable-video", events.get(0).get("track"));
    assertFalse(events.get(0).containsKey("transceiver"));
    assertEquals(1, failures.size());
  }

  @Test
  public void requiredTrackFailureDoesNotEscapeAndCanNotifyDart() {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    List<String> states = new ArrayList<>();
    guard.run(() -> {
      throw new IllegalStateException("MediaStreamTrack has been disposed");
    }, error -> states.add("failed"));
    assertEquals(java.util.Collections.singletonList("failed"), states);
    AtomicBoolean nextCallback = new AtomicBoolean();
    guard.run(() -> nextCallback.set(true), error -> fail());
    assertTrue(nextCallback.get());
  }

  @Test
  public void terminationIsIdempotentAndDropsLateCallbacksAndMetadata() {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    assertTrue(guard.terminate());
    assertFalse(guard.terminate());
    guard.run(() -> fail("late callback must not run"), error -> fail());
    assertNull(guard.optional(() -> {
      fail("late wrapper must not be read");
      return "metadata";
    }, error -> fail()));
  }

  @Test
  public void terminationDoesNotWaitForAnInFlightSignalingCallback() throws Exception {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    CountDownLatch entered = new CountDownLatch(1);
    CountDownLatch release = new CountDownLatch(1);
    AtomicBoolean reported = new AtomicBoolean();
    Thread signaling = new Thread(() -> guard.run(() -> {
      entered.countDown();
      try {
        if (!release.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("timeout");
      } catch (InterruptedException error) {
        throw new IllegalStateException(error);
      }
      throw new IllegalStateException("callback became stale during close");
    }, error -> reported.set(true)));
    signaling.start();
    try {
      assertTrue(entered.await(5, TimeUnit.SECONDS));
      assertTrue(guard.terminate());
    } finally {
      release.countDown();
      signaling.join(5000);
    }
    assertFalse(signaling.isAlive());
    assertFalse(reported.get());
  }

  @Test
  public void optionalMetadataIsDiscardedWhenItTerminatesMidRead() {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    assertNull(guard.optional(() -> {
      guard.terminate();
      return "now-disposed";
    }, error -> fail()));
  }

  @Test
  public void failureInRecoveryCannotEscapeIntoJniEither() {
    RemoteTrackCallbackGuard guard = new RemoteTrackCallbackGuard();
    guard.run(() -> {
      throw new NullPointerException("track vanished");
    }, error -> {
      throw new IllegalStateException("event channel closed");
    });
    assertNull(guard.optional(() -> {
      throw new IllegalStateException("disposed");
    }, error -> {
      throw new IllegalStateException("logger failed");
    }));
  }
}
