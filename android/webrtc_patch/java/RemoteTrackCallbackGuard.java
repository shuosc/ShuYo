package com.cloudwebrtc.webrtc;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * A nonblocking JNI callback boundary. Java exceptions must not escape back to
 * libwebrtc: its exception handler deliberately aborts the process.
 *
 * No monitor is held while callbacks or native close/dispose run. Native close
 * may wait for the signaling thread which invokes these callbacks.
 */
final class RemoteTrackCallbackGuard {
  interface Value<T> {
    T get();
  }

  interface Failure {
    void report(RuntimeException error);
  }

  private final AtomicBoolean terminated = new AtomicBoolean();

  boolean terminate() {
    return terminated.compareAndSet(false, true);
  }

  boolean isTerminated() {
    return terminated.get();
  }

  void run(Runnable callback, Failure failure) {
    if (isTerminated()) return;
    try {
      callback.run();
    } catch (RuntimeException error) {
      report(error, failure);
    }
  }

  <T> T optional(Value<T> metadata, Failure failure) {
    if (isTerminated()) return null;
    try {
      T result = metadata.get();
      return isTerminated() ? null : result;
    } catch (RuntimeException error) {
      report(error, failure);
      return null;
    }
  }

  private void report(RuntimeException error, Failure failure) {
    if (isTerminated()) return;
    try {
      failure.report(error);
    } catch (RuntimeException reportingFailure) {
      // A failed logger/event sink must not turn recovery into a JNI abort.
      if (reportingFailure != error) error.addSuppressed(reportingFailure);
    }
  }
}
