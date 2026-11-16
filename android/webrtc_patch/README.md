# Android WebRTC observer patch

This directory replaces one Java class from the published `flutter_webrtc`
**1.6.3** package. Its native SDK remains `io.github.webrtc-sdk:android:150.7871.04`.
The Pub cache is not modified and the plugin's other platforms are unchanged.

`java/PeerConnectionObserver.java` was copied from the package's
`android/src/main/java/com/cloudwebrtc/webrtc/PeerConnectionObserver.java`.
The upstream MIT license is preserved in [LICENSE](LICENSE). Local changes are
limited to callback lifetime, remote track registration, nondestructive track
lookup and optional metadata serialization.

## Why this exists

An exception in `PeerConnection.Observer.onAddTrack` crosses the JNI boundary and
libwebrtc calls `abort()`. The observed arm64 native library has Build ID
`f2f2109550c96a97`; disassembly of its crash addresses identifies the Java
`onAddTrack` callback and `jvm.cc` exception handler.

The SDK's `PeerConnection.getTransceivers()` disposes previously returned Java
wrappers. Enumerating that cache from the signaling callback can race main-thread
serialization or playback teardown. This is also reported upstream in
[flutter-webrtc issue 2232](https://github.com/flutter-webrtc/flutter-webrtc/issues/2232).
The JNI behavior is documented by the upstream
[exception handler](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/src/jni/jvm.cc).

The patch:

- Registers the callback receiver's track **before sending any track event**.
- Starts media audio focus for an audio track even when it has no associated
  stream; the Dart layer configures the plugin's media playback attributes.
- Never calls destructive `getTransceivers()` from `onAddTrack` or renderer track
  lookup. Only observer-owned `onTrack` wrappers are used for optional metadata.
- Allows missing/stale transceiver metadata while still delivering the usable
  stream and track. The existing Dart event parser accepts a null transceiver;
  native `onTrack` can follow `onAddTrack`, so metadata may not be available on
  the first event.
- Contains Java `RuntimeException` at track callback boundaries, reporting a
  failed connection through the existing Dart event when required track data
  cannot be read. Optional metadata failures just omit that metadata.
- Marks termination before native close/dispose, drops late callbacks/events,
  and snapshots the volatile event sink to avoid a concurrent cancel/null race.
- Holds no Java callback lock across native close/dispose, which can otherwise
  deadlock while the signaling thread waits to enter the callback.

## Build integration and validation

[../build.gradle.kts](../build.gradle.kts) excludes only the upstream
package-relative observer file and adds this flat `java` directory to that
plugin's Java sources. Keep the replacement flat: moving it beneath
`com/cloudwebrtc/webrtc` would also match the exclusion. The guard is an ordinary
Java helper without Android dependencies.

From the `android` directory:

```powershell
./gradlew.bat :flutter_webrtc:testDebugUnitTest :flutter_webrtc:compileReleaseJavaWithJavac
```

`test/RemoteTrackCallbackGuardTest.java` exercises real throwing callbacks,
metadata failure that preserves playback data, termination, an in-flight callback
without blocking termination, and a failing recovery handler. These JVM tests
do not claim to reproduce or validate native decoding on a physical device.

The build checks the plugin's version before applying this replacement. When
upgrading `flutter_webrtc`, compare it against the new upstream class and remove
the override when its equivalent fix is included.
