import 'dart:math';
import 'dart:ui';

/// Tipo de cada segmento do anel de um andar.
enum SegType { gap, safe, danger }

enum EnemyKind { walker, spiky }

enum ItemKind { coin, mushroom, star }

class Enemy {
  Enemy({
    required this.kind,
    required this.center,
    required this.halfRange,
    required this.speed,
    required this.phase,
  });

  final EnemyKind kind;

  /// Patrulha em vai-e-vem: theta = center + sin(phase) * halfRange.
  final double center;
  final double halfRange;
  final double speed;
  double phase;
  bool dead = false;

  double get theta => center + sin(phase) * halfRange;

  /// Direção de caminhada (para espelhar o sprite).
  bool get facingRight => cos(phase) >= 0;

  void update(double dt) {
    if (halfRange > 0.01) phase += speed * dt;
  }
}

class FloorItem {
  FloorItem({required this.kind, required this.theta, required this.bobPhase});

  final ItemKind kind;
  final double theta;
  final double bobPhase;
  bool taken = false;
}

class Floor {
  Floor({required this.index, required this.y, required this.segs});

  final int index;

  /// Coordenada Y do topo da plataforma (Y cresce para baixo).
  final double y;
  final List<SegType> segs;
  bool broken = false;
  final enemies = <Enemy>[];
  final items = <FloorItem>[];

  SegType segAt(double localTheta) {
    final a = localTheta % (2 * pi);
    final idx = (a / Tower.segAngle).floor() % Tower.segCount;
    return broken ? SegType.gap : segs[idx];
  }
}

class Tower {
  Tower(int seed) : rnd = Random(seed);

  static const segCount = 12;
  static const segAngle = 2 * pi / segCount;
  static const floorSpacing = 150.0;
  static const thickness = 26.0;
  static const outerR = 150.0;
  static const poleR = 40.0;
  static const firstY = 200.0;

  final Random rnd;
  final floors = <Floor>[];

  static double floorY(int index) => firstY + index * floorSpacing;

  void ensureFloors(int upTo) {
    while (floors.length <= upTo) {
      floors.add(_generate(floors.length));
    }
  }

  Floor _generate(int d) {
    final segs = List.filled(segCount, SegType.safe);
    final floor = Floor(index: d, y: floorY(d), segs: segs);
    if (d == 0) {
      // Plataforma inicial: segura, com um vão no lado oposto ao spawn.
      segs[5] = SegType.gap;
      segs[6] = SegType.gap;
      segs[7] = SegType.gap;
      return floor;
    }

    // --- Vãos (por onde se cai) ---
    final gapRuns = (d > 8 && rnd.nextDouble() < 0.35) ? 2 : 1;
    for (var r = 0; r < gapRuns; r++) {
      var width = 2 + rnd.nextInt(2);
      if (d > 15 && rnd.nextDouble() < 0.35) width = 1 + rnd.nextInt(2);
      final start = rnd.nextInt(segCount);
      for (var i = 0; i < width; i++) {
        segs[(start + i) % segCount] = SegType.gap;
      }
    }

    // --- Segmentos de perigo (lava com espinhos) ---
    var dangerRuns = d < 3
        ? 0
        : d < 8
            ? 1
            : d < 16
                ? 1 + rnd.nextInt(2)
                : 2 + rnd.nextInt(2);
    var dangerCells = 0;
    while (dangerRuns > 0 && dangerCells < 4) {
      dangerRuns--;
      final width = (d > 10 && rnd.nextDouble() < 0.4) ? 2 : 1;
      for (var attempt = 0; attempt < 20; attempt++) {
        final start = rnd.nextInt(segCount);
        var ok = true;
        for (var i = 0; i < width; i++) {
          if (segs[(start + i) % segCount] != SegType.safe) ok = false;
        }
        if (!ok) continue;
        for (var i = 0; i < width; i++) {
          segs[(start + i) % segCount] = SegType.danger;
          dangerCells++;
        }
        break;
      }
    }

    // Garante pelo menos 3 segmentos seguros consecutivos em algum lugar.
    if (!_hasSafeRun(segs, 3)) {
      final start = rnd.nextInt(segCount);
      for (var i = 0; i < 3; i++) {
        if (segs[(start + i) % segCount] == SegType.danger) {
          segs[(start + i) % segCount] = SegType.safe;
        }
      }
    }

    // --- Inimigos patrulhando trechos seguros ---
    final enemyChance = d < 5 ? 0.0 : min(0.15 + d * 0.012, 0.55);
    if (rnd.nextDouble() < enemyChance) {
      final run = _randomSafeRun(segs);
      if (run != null) {
        final (startSeg, len) = run;
        final a0 = startSeg * segAngle + 0.18;
        final a1 = (startSeg + len) * segAngle - 0.18;
        final spikyRatio = min(0.3 + d * 0.01, 0.6);
        floor.enemies.add(Enemy(
          kind: rnd.nextDouble() < spikyRatio
              ? EnemyKind.spiky
              : EnemyKind.walker,
          center: (a0 + a1) / 2,
          halfRange: max(0, (a1 - a0) / 2),
          speed: 0.9 + min(d * 0.025, 1.1) + rnd.nextDouble() * 0.4,
          phase: rnd.nextDouble() * 2 * pi,
        ));
      }
    }

    // --- Itens ---
    if (rnd.nextDouble() < 0.4) {
      // Trilha de 3 moedas sobre segmentos consecutivos.
      final start = rnd.nextInt(segCount);
      for (var i = 0; i < 3; i++) {
        floor.items.add(FloorItem(
          kind: ItemKind.coin,
          theta: (start + i + 0.5) * segAngle,
          bobPhase: i * 0.7,
        ));
      }
    }
    if (d > 4 && d % 9 == 0 && rnd.nextDouble() < 0.85) {
      floor.items.add(FloorItem(
        kind: ItemKind.mushroom,
        theta: rnd.nextDouble() * 2 * pi,
        bobPhase: rnd.nextDouble() * 2 * pi,
      ));
    } else if (d > 8 && rnd.nextDouble() < 0.06) {
      floor.items.add(FloorItem(
        kind: ItemKind.star,
        theta: rnd.nextDouble() * 2 * pi,
        bobPhase: rnd.nextDouble() * 2 * pi,
      ));
    }

    return floor;
  }

  bool _hasSafeRun(List<SegType> segs, int len) {
    for (var s = 0; s < segCount; s++) {
      var ok = true;
      for (var i = 0; i < len; i++) {
        if (segs[(s + i) % segCount] != SegType.safe) ok = false;
      }
      if (ok) return true;
    }
    return false;
  }

  /// Sorteia um trecho contíguo de segmentos seguros (início, comprimento).
  (int, int)? _randomSafeRun(List<SegType> segs) {
    final starts = <int>[];
    for (var s = 0; s < segCount; s++) {
      if (segs[s] == SegType.safe &&
          segs[(s - 1 + segCount) % segCount] != SegType.safe) {
        starts.add(s);
      }
    }
    if (starts.isEmpty) {
      // Anel todo seguro.
      return segs.every((s) => s == SegType.safe) ? (0, segCount) : null;
    }
    final start = starts[rnd.nextInt(starts.length)];
    var len = 0;
    while (segs[(start + len) % segCount] == SegType.safe && len < segCount) {
      len++;
    }
    return len >= 2 ? (start, len) : null;
  }
}

/// Particulas em espaco de tela (entulho de plataformas, poeira, faiscas).
class Particle {
  Particle({
    required this.pos,
    required this.vel,
    required this.color,
    required this.size,
    required this.life,
    this.gravity = 1800,
    this.spin = 0,
  }) : maxLife = life;

  Offset pos;
  Offset vel;
  final Color color;
  final double size;
  double life;
  final double maxLife;
  final double gravity;
  final double spin;
  double angle = 0;

  bool update(double dt) {
    pos += vel * dt;
    vel = Offset(vel.dx, vel.dy + gravity * dt);
    angle += spin * dt;
    life -= dt;
    return life > 0;
  }
}

/// Texto flutuante de pontuacao ("+100").
class FloatText {
  FloatText({required this.pos, required this.text, this.life = 0.9})
      : maxLife = life;

  Offset pos;
  final String text;
  double life;
  final double maxLife;

  bool update(double dt) {
    pos += Offset(0, -55 * dt);
    life -= dt;
    return life > 0;
  }
}
