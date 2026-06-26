import 'dart:ui' as ui;

/// Stub para plataformas não-web. O protótipo só usa [WebFaceCapture] quando
/// `kIsWeb` é verdadeiro; aqui tudo é no-op para o build nativo compilar.
class WebFaceCapture {
  bool get isSupported => false;

  String get status => 'unavailable';

  String? get errorMessage => null;

  bool get hasFace => false;

  Future<void> start() async {}

  void stop() {}

  Future<ui.Image?> takeFrameIfNew() async => null;
}
