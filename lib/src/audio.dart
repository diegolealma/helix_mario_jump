import 'package:flame_audio/flame_audio.dart';

/// Camada fina sobre o flame_audio: pré-carrega e toca os efeitos do jogo.
///
/// Os WAVs ficam em `assets/audio/` e são gerados por `tools/gen_audio.py`.
class GameAudio {
  GameAudio._();

  static bool muted = false;
  static bool _ready = false;

  static const jump = 'jump.wav';
  static const coin = 'coin.wav';
  static const stomp = 'stomp.wav';
  static const brick = 'brick.wav';
  static const powerup = 'powerup.wav';
  static const star = 'star.wav';
  static const hurt = 'hurt.wav';
  static const death = 'death.wav';
  static const gameover = 'gameover.wav';
  static const start = 'start.wav';
  static const fever = 'fever.wav';

  static const _all = <String>[
    jump, coin, stomp, brick, powerup, star,
    hurt, death, gameover, start, fever,
  ];

  /// Pré-carrega todos os efeitos no cache (chame no onLoad).
  static Future<void> load() async {
    if (_ready) return;
    try {
      await FlameAudio.audioCache.loadAll(_all);
      _ready = true;
    } catch (_) {
      // Sem áudio disponível (ex.: build sem assets) — o jogo segue mudo.
    }
  }

  /// Toca um efeito. Ignora silenciosamente qualquer falha de áudio
  /// (autoplay bloqueado, web sem gesto, etc.).
  static void play(String name, {double volume = 1.0}) {
    if (muted || !_ready) return;
    try {
      FlameAudio.play(name, volume: volume);
    } catch (_) {}
  }

  static void toggleMute() => muted = !muted;
}
