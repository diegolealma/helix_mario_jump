import 'dart:async';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/foundation.dart';

/// Camada fina sobre o flame_audio: pré-carrega e toca os efeitos do jogo.
///
/// Os WAVs ficam em `assets/audio/` e são gerados por `tools/gen_audio.py`.
/// O prefix padrão do flame_audio (`assets/audio/`) já é o correto: no web,
/// o audioplayers monta a URL como `assets/<prefix><arquivo>`, resultando em
/// `assets/assets/audio/<arquivo>`, que é onde o build de produção os serve.
class GameAudio {
  GameAudio._();

  static bool muted = false;

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

  /// Pré-carrega os efeitos (otimização). É best-effort: se o preload falhar,
  /// o áudio NÃO é desabilitado — cada [play] recarrega sob demanda.
  static Future<void> load() async {
    try {
      await FlameAudio.audioCache.loadAll(_all);
    } catch (e, st) {
      debugPrint('GameAudio: preload falhou (segue sob demanda): $e\n$st');
    }
  }

  /// Toca um efeito (fire-and-forget). Falhas de áudio nunca quebram o jogo.
  static void play(String name, {double volume = 1.0}) {
    if (muted) return;
    unawaited(_playSafe(name, volume));
  }

  static Future<void> _playSafe(String name, double volume) async {
    try {
      await FlameAudio.play(name, volume: volume);
    } catch (e) {
      debugPrint('GameAudio: falha ao tocar $name: $e');
    }
  }

  static void toggleMute() => muted = !muted;
}
