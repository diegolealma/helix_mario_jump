import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String?> probeRawWebCameraAccess() async {
  try {
    final mediaDevices = web.window.navigator.mediaDevices;
    final stream = await mediaDevices
        .getUserMedia(
          web.MediaStreamConstraints(
            audio: false.toJS,
            video: true.toJS,
          ),
        )
        .toDart;

    for (final track in stream.getTracks().toDart) {
      track.stop();
    }

    return null;
  } catch (error) {
    return error.toString();
  }
}
