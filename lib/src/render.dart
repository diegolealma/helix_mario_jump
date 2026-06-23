import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/components.dart' show Vector2;
import 'package:flutter/painting.dart';

import 'game.dart';
import 'model.dart';
import 'palette.dart';
import 'sprites.dart';

/// Renderizador pseudo-3D: projeta o cilindro da torre no canvas 2D,
/// com estética de Super Mario World (SNES).
class Renderer {
  Renderer(this.g);

  final SuperHelixGame g;
  final _rng = Random();
  final _paint = Paint();

  static const _cx = designW / 2;
  static const _sub = 3; // subdivisões por segmento (fatias de 10°)

  // ----------------------------------------------------------- projeção

  /// Projeta um ponto do cilindro (ângulo de tela, raio, Y do mundo).
  Offset _proj(double screenAngle, double r, double y) => Offset(
        _cx + sin(screenAngle) * r,
        (y - g.camY) + cos(screenAngle) * r * SuperHelixGame.tilt,
      );

  double _playerScreenY(double y) =>
      (y - g.camY) + SuperHelixGame.playerOrbitR * SuperHelixGame.tilt;

  // ------------------------------------------------------------- render

  void render(Canvas c, Vector2 size) {
    final scale = min(size.x / designW, size.y / designH);
    final offX = (size.x - designW * scale) / 2;
    final offY = (size.y - designH * scale) / 2;

    c.save();
    c.translate(offX, offY);
    c.scale(scale);
    c.clipRect(Rect.fromLTWH(0, 0, designW, designH));

    if (g.shakeT > 0) {
      c.translate((_rng.nextDouble() - 0.5) * 10 * g.shakeT,
          (_rng.nextDouble() - 0.5) * 10 * g.shakeT);
    }

    _drawBackground(c);
    if (g.state != GState.loading) {
      _drawTower(c);
      _drawPlayer(c);
      _drawParticles(c);
      _drawFloatTexts(c);
      switch (g.state) {
        case GState.playing || GState.dying:
          _drawHud(c);
        case GState.title:
          _drawTitle(c);
        case GState.gameOver:
          _drawHud(c);
          _drawGameOver(c);
        default:
          break;
      }
    }
    c.restore();

    // Barras de letterbox.
    _paint
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.fill;
    if (offX > 0) {
      c.drawRect(Rect.fromLTWH(0, 0, offX, size.y), _paint);
      c.drawRect(Rect.fromLTWH(size.x - offX, 0, offX, size.y), _paint);
    }
    if (offY > 0) {
      c.drawRect(Rect.fromLTWH(0, 0, size.x, offY), _paint);
      c.drawRect(Rect.fromLTWH(0, size.y - offY, size.x, offY), _paint);
    }
  }

  // --------------------------------------------------------------- céu

  void _drawBackground(Canvas c) {
    const rect = Rect.fromLTWH(0, 0, designW, designH);
    _paint
      ..style = PaintingStyle.fill
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        [Pal.skyTop, Pal.skyBottom],
      );
    c.drawRect(rect, _paint);
    _paint.shader = null;

    // Nuvens à deriva.
    _drawCloud(c, (g.time * 9) % (designW + 200) - 100, 110, 1.0);
    _drawCloud(c, (g.time * 14 + 260) % (designW + 200) - 100, 230, 0.7);
    _drawCloud(c, (g.time * 6 + 90) % (designW + 200) - 100, 560, 0.85);
    _drawCloud(c, (g.time * 11 + 380) % (designW + 200) - 100, 700, 0.6);

    // Colinas no horizonte inferior.
    _drawHill(c, 70, designH, 200, 150);
    _drawHill(c, 430, designH, 160, 110);
    _drawBush(c, 250, designH, 90, 42);
  }

  void _drawCloud(Canvas c, double x, double y, double s) {
    _paint
      ..style = PaintingStyle.fill
      ..color = Pal.cloud;
    c.drawCircle(Offset(x - 24 * s, y), 16 * s, _paint);
    c.drawCircle(Offset(x, y - 10 * s), 22 * s, _paint);
    c.drawCircle(Offset(x + 26 * s, y), 17 * s, _paint);
    c.drawRect(Rect.fromLTWH(x - 38 * s, y - 2 * s, 76 * s, 16 * s), _paint);
    _paint.color = Pal.cloudShade;
    c.drawRect(Rect.fromLTWH(x - 34 * s, y + 10 * s, 68 * s, 4 * s), _paint);
  }

  void _drawHill(Canvas c, double cx, double baseY, double w, double h) {
    final rect =
        Rect.fromCenter(center: Offset(cx, baseY), width: w * 2, height: h * 2);
    final path = Path()
      ..moveTo(cx - w, baseY)
      ..arcTo(rect, pi, pi, false)
      ..close();
    _paint
      ..style = PaintingStyle.fill
      ..color = Pal.hillLight;
    c.drawPath(path, _paint);
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = Pal.hillOutline;
    c.drawPath(path, _paint);
    // Pintinhas características das colinas do SMW.
    _paint
      ..style = PaintingStyle.fill
      ..color = Pal.hillDark;
    for (var i = 0; i < 5; i++) {
      final px = cx + (i * 37 % (w * 1.2)) - w * 0.6;
      final py = baseY - (i * 23 % (h * 0.8)) - h * 0.1;
      c.drawOval(Rect.fromCenter(center: Offset(px, py), width: 14, height: 8),
          _paint);
    }
  }

  void _drawBush(Canvas c, double cx, double baseY, double w, double h) {
    _paint
      ..style = PaintingStyle.fill
      ..color = Pal.hillMid;
    c.drawCircle(Offset(cx - w * 0.5, baseY - h * 0.3), h * 0.55, _paint);
    c.drawCircle(Offset(cx, baseY - h * 0.5), h * 0.7, _paint);
    c.drawCircle(Offset(cx + w * 0.5, baseY - h * 0.3), h * 0.55, _paint);
    c.drawRect(
        Rect.fromLTWH(cx - w * 0.7, baseY - h * 0.3, w * 1.4, h * 0.3), _paint);
  }

  // ------------------------------------------------------------- torre

  void _drawTower(Canvas c) {
    final floors = g.visibleFloors();

    // 1) Metades de trás dos andares (atrás do cano).
    for (final f in floors) {
      _drawFloorHalf(c, f, back: true);
    }
    // 2) Entidades na metade de trás.
    for (final f in floors) {
      _drawEntities(c, f, back: true);
    }
    _drawFireShots(c, back: true);
    // 3) Cano central.
    _drawPole(c);
    // 4) Metades da frente.
    for (final f in floors) {
      _drawFloorHalf(c, f, back: false);
    }
    for (final f in floors) {
      _drawEntities(c, f, back: false);
    }
    _drawFireShots(c, back: false);
  }

  void _drawPole(Canvas c) {
    _paint.style = PaintingStyle.fill;
    const r = Tower.poleR;
    // Corpo do cano com faixas de iluminação.
    _paint.color = Pal.pipeDark;
    c.drawRect(const Rect.fromLTWH(_cx - r, 0, r * 2, designH), _paint);
    _paint.color = Pal.pipe;
    c.drawRect(
        const Rect.fromLTWH(_cx - r + 8, 0, r * 2 - 20, designH), _paint);
    _paint.color = Pal.pipeLight;
    c.drawRect(const Rect.fromLTWH(_cx - r + 14, 0, 10, designH), _paint);
    _paint.color = Pal.pipeDarker;
    c.drawRect(const Rect.fromLTWH(_cx + r - 6, 0, 6, designH), _paint);

    // Anéis do cano (ancorados no mundo: dão sensação de descida).
    _paint.color = Pal.pipeDarker.withValues(alpha: 0.55);
    final first = (g.camY / Tower.floorSpacing).floor() - 1;
    for (var k = first; k < first + 9; k++) {
      final ringY = k * Tower.floorSpacing + Tower.firstY - 70 - g.camY;
      if (ringY < -20 || ringY > designH + 20) continue;
      c.drawRect(Rect.fromLTWH(_cx - r, ringY, r * 2, 7), _paint);
    }
  }

  void _drawFloorHalf(Canvas c, Floor f, {required bool back}) {
    if (f.broken) return;
    const slices = Tower.segCount * _sub;
    const sliceA = 2 * pi / slices;
    final lavaPulse = 0.5 + 0.5 * sin(g.time * 5 + f.index * 1.3);

    for (var i = 0; i < slices; i++) {
      final seg = f.segs[i ~/ _sub];
      if (seg == SegType.gap) continue;
      final a1 = i * sliceA + g.rot - 0.012;
      final a2 = (i + 1) * sliceA + g.rot + 0.012;
      final mid = (a1 + a2) / 2;
      final z = cos(mid);
      if (back ? z >= 0 : z < 0) continue;

      final i1 = _proj(a1, Tower.poleR, f.y);
      final i2 = _proj(a2, Tower.poleR, f.y);
      final o1 = _proj(a1, Tower.outerR, f.y);
      final o2 = _proj(a2, Tower.outerR, f.y);
      final light = (z + 1) / 2; // 0 atrás, 1 na frente

      // Face lateral externa (espessura) — visível na metade da frente.
      if (!back) {
        final b1 = o1 + const Offset(0, Tower.thickness);
        final b2 = o2 + const Offset(0, Tower.thickness);
        final side = Path()
          ..moveTo(o1.dx, o1.dy)
          ..lineTo(o2.dx, o2.dy)
          ..lineTo(b2.dx, b2.dy)
          ..lineTo(b1.dx, b1.dy)
          ..close();
        _paint
          ..style = PaintingStyle.fill
          ..color = seg == SegType.safe
              ? Color.lerp(Pal.dirtDarker, Pal.dirt, light)!
              : Color.lerp(Pal.lavaDarker, Pal.lavaDark, light)!;
        c.drawPath(side, _paint);
        // Linha divisória do "bolo" de terra.
        _paint.color = seg == SegType.safe
            ? Pal.dirtDark.withValues(alpha: 0.7)
            : Pal.lavaDarker.withValues(alpha: 0.7);
        c.drawRect(
            Rect.fromLTRB(min(o1.dx, o2.dx), o1.dy + Tower.thickness * 0.55,
                max(o1.dx, o2.dx), o1.dy + Tower.thickness * 0.55 + 3),
            _paint);
      }

      // Face superior.
      final top = Path()
        ..moveTo(i1.dx, i1.dy)
        ..lineTo(o1.dx, o1.dy)
        ..lineTo(o2.dx, o2.dy)
        ..lineTo(i2.dx, i2.dy)
        ..close();
      _paint
        ..style = PaintingStyle.fill
        ..color = seg == SegType.safe
            ? Color.lerp(Pal.grassDark, Pal.grass, 0.35 + 0.65 * light)!
            : Color.lerp(Pal.lavaDark,
                Color.lerp(Pal.lava, Pal.lavaLight, lavaPulse)!, light)!;
      c.drawPath(top, _paint);

      // Borda externa da grama (contorno estilo SNES).
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = seg == SegType.safe
            ? (back ? Pal.grassDark : Pal.grassLight)
            : Pal.lavaDarker;
      c.drawLine(o1, o2, _paint);
    }

    // Espinhos sobre os segmentos de perigo (frente apenas).
    if (!back) _drawSpikes(c, f);
  }

  void _drawSpikes(Canvas c, Floor f) {
    const segA = Tower.segAngle;
    for (var s = 0; s < Tower.segCount; s++) {
      if (f.segs[s] != SegType.danger) continue;
      for (final frac in const [0.28, 0.72]) {
        final a = (s + frac) * segA + g.rot;
        final z = cos(a);
        if (z <= 0.05) continue;
        final base = _proj(a, (Tower.poleR + Tower.outerR) * 0.55, f.y);
        final h = 15 * (0.6 + 0.4 * z);
        final w = 6.5 * (0.6 + 0.4 * z);
        final spike = Path()
          ..moveTo(base.dx - w, base.dy)
          ..lineTo(base.dx + w, base.dy)
          ..lineTo(base.dx, base.dy - h)
          ..close();
        _paint
          ..style = PaintingStyle.fill
          ..color = Pal.spike;
        c.drawPath(spike, _paint);
        _paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Pal.spikeDark;
        c.drawPath(spike, _paint);
      }
    }
  }

  // --------------------------------------------------- inimigos e itens

  void _drawEntities(Canvas c, Floor f, {required bool back}) {
    if (f.broken) return;
    for (final e in f.enemies) {
      if (e.dead) continue;
      final sa = e.theta + g.rot;
      final z = cos(sa);
      if (back ? z >= 0 : z < 0) continue;
      final pos = _proj(sa, SuperHelixGame.playerOrbitR, f.y);
      final scale = 0.72 + 0.28 * z;
      late ui.Image img;
      late double h;
      var rotation = 0.0;
      switch (e.kind) {
        case EnemyKind.walker:
          img = g.sprites.goomba;
          h = 34 * scale;
        case EnemyKind.spiky:
          img = g.sprites.spiky;
          h = 34 * scale;
        case EnemyKind.koopaGreen:
          img = g.sprites.koopaGreen;
          h = 46 * scale;
        case EnemyKind.koopaRed:
          img = g.sprites.koopaRed;
          h = 46 * scale;
        case EnemyKind.shellGreen:
          img = g.sprites.shellGreen;
          h = 25 * scale;
          rotation = e.shellSpin;
        case EnemyKind.shellRed:
          img = g.sprites.shellRed;
          h = 25 * scale;
          rotation = e.shellSpin;
      }
      final wob =
          e.kind == EnemyKind.walker ? sin(g.time * 10 + e.phase) * 0.06 : 0.0;
      final originalFacesLeft =
          e.kind == EnemyKind.koopaGreen || e.kind == EnemyKind.koopaRed;
      drawSprite(
        c,
        img,
        pos,
        h,
        flipX: originalFacesLeft ? e.facingRight : !e.facingRight,
        scaleX: 1 + wob,
        scaleY: 1 - wob,
        rotation: rotation,
      );
    }

    for (final item in f.items) {
      if (item.taken) continue;
      final sa = item.theta + g.rot;
      final z = cos(sa);
      if (back ? z >= 0 : z < 0) continue;
      final bob = sin(g.time * 3 + item.bobPhase) * 6;
      final y = f.y - 58 + bob;
      final pos = _proj(sa, SuperHelixGame.playerOrbitR, y);
      final s = 0.72 + 0.28 * z;
      switch (item.kind) {
        case ItemKind.coin:
          final spin = cos(g.time * 5 + item.bobPhase).abs();
          drawSprite(c, g.sprites.coin, pos + const Offset(0, 12), 26 * s,
              scaleX: 0.25 + 0.75 * spin);
        case ItemKind.mushroom:
          _glow(c, pos + const Offset(0, -2), 26 * s, Pal.white);
          drawSprite(c, g.sprites.mushroom, pos + const Offset(0, 13), 30 * s);
        case ItemKind.fireFlower:
          _glow(c, pos + const Offset(0, -2), 28 * s, Pal.lavaLight);
          drawSprite(
              c, g.sprites.fireFlower, pos + const Offset(0, 14), 31 * s);
        case ItemKind.star:
          _glow(c, pos + const Offset(0, -2), 30 * s,
              Pal.hudYellow.withValues(alpha: 0.9));
          drawSprite(c, g.sprites.star, pos + const Offset(0, 14), 30 * s);
      }
    }
  }

  void _drawFireShots(Canvas c, {required bool back}) {
    for (final shot in g.visibleFireShots()) {
      final sa = shot.theta + g.rot;
      final z = cos(sa);
      if (back ? z >= 0 : z < 0) continue;
      final pos = _proj(sa, SuperHelixGame.playerOrbitR, shot.y);
      final s = 0.72 + 0.28 * z;
      _glow(c, pos, 15 * s, Pal.lavaLight);
      drawSprite(c, g.sprites.fireball, pos + Offset(0, 8 * s), 18 * s,
          rotation: shot.spin);
    }
  }

  void _glow(Canvas c, Offset center, double r, Color color) {
    final pulse = 0.7 + 0.3 * sin(g.time * 6);
    _paint
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.30 * pulse);
    c.drawCircle(center, r * pulse, _paint);
  }

  // ----------------------------------------------------------- jogador

  void _drawPlayer(Canvas c) {
    final px = _cx;
    final pyScreen = _playerScreenY(g.py);

    _drawShadow(c);

    // Pisca durante a invencibilidade pós-dano.
    if (g.invulnT > 0 && (g.time * 12).floor().isEven) return;

    final falling = g.vy > 0;
    final img = falling || g.state == GState.dying
        ? g.sprites.playerFall
        : g.sprites.playerJump;
    final h = g.superForm ? 62.0 : 46.0;

    // Aura de fogo no modo fever / brilho da estrela.
    if (g.state == GState.playing) {
      if (g.starT > 0) {
        final hue = (g.time * 300) % 360;
        _paint
          ..style = PaintingStyle.fill
          ..color = HSVColor.fromAHSV(0.45, hue, 0.9, 1).toColor();
        c.drawCircle(Offset(px, pyScreen - h / 2), h * 0.85, _paint);
      } else if (g.firePower) {
        _paint
          ..style = PaintingStyle.fill
          ..color = Pal.lavaLight
              .withValues(alpha: 0.18 + 0.08 * sin(g.time * 8).abs());
        c.drawCircle(Offset(px, pyScreen - h / 2), h * 0.72, _paint);
      } else if (g.fever && falling) {
        final flick = 0.85 + 0.15 * sin(g.time * 30);
        _paint
          ..style = PaintingStyle.fill
          ..color = Pal.lava.withValues(alpha: 0.55);
        c.drawOval(
            Rect.fromCenter(
                center: Offset(px, pyScreen - h * 0.35),
                width: h * 0.95 * flick,
                height: h * 1.5 * flick),
            _paint);
        _paint.color = Pal.hudYellow.withValues(alpha: 0.75);
        c.drawOval(
            Rect.fromCenter(
                center: Offset(px, pyScreen - h * 0.3),
                width: h * 0.55 * flick,
                height: h * 0.95 * flick),
            _paint);
      }
    }

    // Squash & stretch.
    var sx = 1.0, sy = 1.0;
    final sinceBounce = g.time - g.lastBounceT;
    if (sinceBounce < 0.09) {
      sx = 1.22;
      sy = 0.74;
    } else if (g.vy > 700) {
      sx = 0.92;
      sy = 1.1;
    }

    if (g.state == GState.dying) {
      // Animação clássica de morte: gira caindo.
      c.save();
      c.translate(px, pyScreen - h / 2);
      c.rotate(g.stateT * 6);
      drawSprite(c, img, Offset(0, h / 2), h);
      c.restore();
      return;
    }

    void drawCurrent({Paint? paint}) {
      if (g.spinDive && g.state == GState.playing) {
        c.save();
        c.translate(px, pyScreen - h / 2);
        c.rotate(g.spinAngle);
        drawSprite(c, img, Offset(0, h / 2), h,
            scaleX: sx, scaleY: sy, paint: paint);
        c.restore();
      } else {
        drawSprite(c, img, Offset(px, pyScreen), h,
            scaleX: sx, scaleY: sy, paint: paint);
      }
    }

    drawCurrent();

    if (g.firePower && g.starT <= 0 && g.state == GState.playing) {
      final fireTint = Paint()
        ..filterQuality = FilterQuality.none
        ..colorFilter = ColorFilter.mode(
            Pal.lavaLight.withValues(alpha: 0.28), BlendMode.srcATop);
      drawCurrent(paint: fireTint);
    }

    // Tinta cintilante da estrela por cima do sprite.
    if (g.starT > 0 && g.state == GState.playing) {
      final hue = (g.time * 540) % 360;
      final tint = Paint()
        ..filterQuality = FilterQuality.none
        ..colorFilter = ColorFilter.mode(
            HSVColor.fromAHSV(0.5, hue, 1, 1).toColor(), BlendMode.srcATop);
      drawCurrent(paint: tint);
    }
  }

  void _drawShadow(Canvas c) {
    if (g.state == GState.dying) return;
    final local = ((-g.rot) % (2 * pi) + 2 * pi) % (2 * pi);
    Floor? target;
    for (final f in g.tower.floors) {
      if (f.y < g.py) continue;
      if (f.broken) continue;
      if (f.segAt(local) != SegType.gap) {
        target = f;
        break;
      }
      if (f.y - g.py > 1400) break;
    }
    if (target == null) return;
    final sy = _playerScreenY(target.y);
    if (sy > designH + 40) return;
    final dist = (target.y - g.py).clamp(0, 700);
    final wFactor = 1 - dist / 1000;
    _paint
      ..style = PaintingStyle.fill
      ..color = const Color(0x40000000);
    c.drawOval(
        Rect.fromCenter(
            center: Offset(_cx, sy), width: 46 * wFactor, height: 14 * wFactor),
        _paint);
  }

  // --------------------------------------------------------- partículas

  void spawnDebris(Floor f) {
    const slices = Tower.segCount;
    for (var s = 0; s < slices; s++) {
      if (f.segs[s] == SegType.gap) continue;
      final a = (s + 0.5) * Tower.segAngle + g.rot;
      for (var k = 0; k < 2; k++) {
        final r = Tower.poleR +
            (Tower.outerR - Tower.poleR) * (0.3 + 0.55 * _rng.nextDouble());
        final pos = _proj(a, r, f.y);
        final dir = (pos - Offset(_cx, pos.dy)).dx.sign;
        final outward = dir == 0 ? (_rng.nextBool() ? 1 : -1) : dir;
        g.particles.add(Particle(
          pos: pos,
          vel: Offset(outward * (60 + _rng.nextDouble() * 200) + sin(a) * 80,
              -120 - _rng.nextDouble() * 160),
          color: f.segs[s] == SegType.safe
              ? (k == 0 ? Pal.grass : Pal.dirt)
              : (k == 0 ? Pal.lava : Pal.lavaDark),
          size: 9 + _rng.nextDouble() * 8,
          life: 0.7 + _rng.nextDouble() * 0.4,
          spin: (_rng.nextDouble() - 0.5) * 14,
        ));
      }
    }
  }

  void spawnDust(double floorY) {
    final base = Offset(_cx, _playerScreenY(floorY));
    for (var i = 0; i < 5; i++) {
      g.particles.add(Particle(
        pos: base + Offset((_rng.nextDouble() - 0.5) * 30, 0),
        vel: Offset(
            (_rng.nextDouble() - 0.5) * 120, -30 - _rng.nextDouble() * 60),
        color: Pal.white.withValues(alpha: 0.8),
        size: 5 + _rng.nextDouble() * 4,
        life: 0.35,
        gravity: 300,
      ));
    }
  }

  void spawnSparkle(double worldY) {
    final base = Offset(_cx, _playerScreenY(worldY));
    for (var i = 0; i < 8; i++) {
      final a = i / 8 * 2 * pi;
      g.particles.add(Particle(
        pos: base,
        vel: Offset(cos(a), sin(a)) * (90 + _rng.nextDouble() * 60),
        color: Pal.hudYellow,
        size: 4 + _rng.nextDouble() * 3,
        life: 0.45,
        gravity: 0,
      ));
    }
  }

  void spawnFireBurst(double worldY) {
    final base = Offset(_cx, _playerScreenY(worldY));
    for (final direction in const [-1.0, 1.0]) {
      for (var i = 0; i < 4; i++) {
        g.particles.add(Particle(
          pos: base,
          vel: Offset(direction * (75 + _rng.nextDouble() * 90),
              (_rng.nextDouble() - 0.5) * 80),
          color: i.isEven ? Pal.lavaLight : Pal.hudYellow,
          size: 4 + _rng.nextDouble() * 3,
          life: 0.35,
          gravity: 0,
        ));
      }
    }
  }

  void spawnStompPoof(Floor f, Enemy e) {
    final pos = _proj(e.theta + g.rot, SuperHelixGame.playerOrbitR, f.y);
    for (var i = 0; i < 7; i++) {
      g.particles.add(Particle(
        pos: pos + Offset(0, -10),
        vel: Offset(
            (_rng.nextDouble() - 0.5) * 220, -50 - _rng.nextDouble() * 120),
        color: i.isEven ? Pal.brown : Pal.tan,
        size: 6 + _rng.nextDouble() * 5,
        life: 0.5,
        spin: (_rng.nextDouble() - 0.5) * 10,
      ));
    }
  }

  void spawnFloatText(double worldY, String text) {
    g.floatTexts.add(FloatText(
      pos: Offset(_cx, _playerScreenY(worldY) - 30),
      text: text,
    ));
  }

  void _drawParticles(Canvas c) {
    _paint.style = PaintingStyle.fill;
    for (final p in g.particles) {
      final alpha = (p.life / p.maxLife).clamp(0.0, 1.0);
      _paint.color = p.color.withValues(alpha: alpha * 0.95);
      c.save();
      c.translate(p.pos.dx, p.pos.dy);
      c.rotate(p.angle);
      c.drawRect(
          Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size),
          _paint);
      c.restore();
    }
  }

  void _drawFloatTexts(Canvas c) {
    for (final t in g.floatTexts) {
      final alpha = (t.life / t.maxLife).clamp(0.0, 1.0);
      _text(c, t.text, t.pos.dx, t.pos.dy, 13,
          Pal.hudWhite.withValues(alpha: alpha),
          align: 'center',
          shadow: Pal.hudShadow.withValues(alpha: alpha * 0.8));
    }
  }

  // ----------------------------------------------------------------- HUD

  void _drawHud(Canvas c) {
    _text(c, 'PONTOS', 18, 16, 11, Pal.hudYellow);
    _text(c, g.score.toString().padLeft(6, '0'), 18, 33, 17, Pal.hudWhite);

    drawSprite(c, g.sprites.coin, const Offset(28, 86), 20);
    _text(c, 'x${g.coins}', 42, 70, 13, Pal.hudWhite);

    _text(c, 'ANDAR', designW - 18, 16, 11, Pal.hudYellow, align: 'right');
    _text(c, '${g.depth}', designW - 18, 33, 17, Pal.hudWhite, align: 'right');

    if (g.firePower) {
      drawSprite(c, g.sprites.fireFlower, const Offset(designW - 30, 86), 23);
    } else if (g.superForm) {
      drawSprite(c, g.sprites.mushroom, const Offset(designW - 30, 86), 22);
    }

    if (g.starT > 0) {
      const w = 150.0;
      final frac = g.starT / 8;
      _paint
        ..style = PaintingStyle.fill
        ..color = const Color(0xAA000000);
      c.drawRect(Rect.fromLTWH(_cx - w / 2 - 2, 16, w + 4, 14), _paint);
      final hue = (g.time * 300) % 360;
      _paint.color = HSVColor.fromAHSV(1, hue, 0.85, 1).toColor();
      c.drawRect(Rect.fromLTWH(_cx - w / 2, 18, w * frac, 10), _paint);
    } else if (g.fever && g.state == GState.playing) {
      final pulse = (g.time * 8).floor().isEven;
      _text(c, 'MODO FOGO!', _cx, 20, 15, pulse ? Pal.lavaLight : Pal.hudYellow,
          align: 'center');
    }
  }

  // --------------------------------------------------------------- telas

  void _drawTitle(Canvas c) {
    _logoText(c, 'SUPER', _cx, 130, 26);
    _logoText(c, 'MAIOR WORLD', _cx, 170, 32);
    _text(c, 'HELIX JUMP EDITION', _cx, 218, 12, Pal.hudWhite, align: 'center');

    if ((g.time * 1.6).floor().isEven) {
      _text(c, 'TOQUE PARA COMECAR', _cx, 600, 15, Pal.hudWhite,
          align: 'center');
    }
    _text(c, 'ARRASTE OU USE SETAS PARA GIRAR', _cx, 642, 9.5, Pal.hudYellow,
        align: 'center');
    _text(c, '2 TOQUES RAPIDOS = PULO DUPLO', _cx, 664, 9.5, Pal.hudYellow,
        align: 'center');
    _text(c, 'PUXE BAIXO = GIRO / CIMA = FOGO', _cx, 686, 9.0, Pal.hudYellow,
        align: 'center');
    _text(c, '3 ANDARES SEM QUICAR = MODO FOGO', _cx, 708, 9.5, Pal.hudYellow,
        align: 'center');
    if (g.best > 0) {
      _text(c, 'RECORDE ${g.best}', _cx, 742, 11, Pal.hudWhite,
          align: 'center');
    }
  }

  void _drawGameOver(Canvas c) {
    _paint
      ..style = PaintingStyle.fill
      ..color = const Color(0x88000000);
    c.drawRect(const Rect.fromLTWH(0, 0, designW, designH), _paint);

    final panel = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: const Offset(_cx, 400), width: 360, height: 320),
        const Radius.circular(14));
    _paint.color = Pal.panel;
    c.drawRRect(panel, _paint);
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Pal.hudWhite;
    c.drawRRect(panel, _paint);

    _logoText(c, 'FIM DE JOGO', _cx, 300, 24);
    _text(c, 'PONTOS  ${g.score}', _cx, 360, 15, Pal.hudWhite, align: 'center');
    _text(c, 'ANDAR   ${g.depth}', _cx, 392, 15, Pal.hudWhite, align: 'center');
    _text(c, 'MOEDAS  ${g.coins}', _cx, 424, 15, Pal.hudWhite, align: 'center');
    if (g.newBest && (g.time * 3).floor().isEven) {
      _text(c, 'NOVO RECORDE!', _cx, 466, 15, Pal.hudYellow, align: 'center');
    } else if (!g.newBest) {
      _text(c, 'RECORDE ${g.best}', _cx, 466, 13, Pal.hudYellow,
          align: 'center');
    }
    if (g.stateT > 0.6 && (g.time * 1.6).floor().isEven) {
      _text(c, 'TOQUE PARA TENTAR DE NOVO', _cx, 520, 12, Pal.hudWhite,
          align: 'center');
    }
  }

  void _logoText(Canvas c, String s, double x, double y, double size) {
    // Contorno preto grosso + sombra, estilo logotipo SNES.
    for (final d in const [
      Offset(-3, 0),
      Offset(3, 0),
      Offset(0, -3),
      Offset(0, 3),
      Offset(-2, -2),
      Offset(2, -2),
      Offset(-2, 2),
      Offset(2, 2),
    ]) {
      _text(c, s, x + d.dx, y + d.dy, size, const Color(0xFF202020),
          align: 'center', shadow: null);
    }
    _text(c, s, x, y + 1.5, size, Pal.darkRed, align: 'center', shadow: null);
    _text(c, s, x, y, size, Pal.hudYellow, align: 'center', shadow: null);
  }

  void _text(Canvas c, String s, double x, double y, double size, Color color,
      {String align = 'left', Color? shadow = Pal.hudShadow}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: 'PressStart2P',
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == 'center'
        ? x - tp.width / 2
        : align == 'right'
            ? x - tp.width
            : x;
    if (shadow != null) {
      final sp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: size,
            color: shadow,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      sp.paint(c, Offset(dx + 2, y + 2));
    }
    tp.paint(c, Offset(dx, y));
  }
}
