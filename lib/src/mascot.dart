import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'palette.dart';

/// Desenha o personagem "cabeçudo": o rosto capturado É a cabeça/corpo, com
/// bracinhos saindo das laterais e calção + perninhas embaixo (no queixo).
///
/// Tudo em um espaço de design fixo (feet em (100, 228), topo em y=8) e depois
/// escalado para [height]. Suporta squash/stretch, rotação (mergulho/morte) e
/// uma tinta opcional (estrela/fogo) aplicada ao personagem inteiro.
void drawFaceGuy(
  Canvas c, {
  required Offset feet,
  required double height,
  ui.Image? face,
  double squashX = 1,
  double squashY = 1,
  double rotation = 0,
  double tick = 0,
  ColorFilter? tint,
}) {
  const designFeetX = 100.0;
  const designFeetY = 228.0;
  const designTop = 8.0;
  final s = height / (designFeetY - designTop);

  c.save();
  c.translate(feet.dx, feet.dy);

  // Tinta global (estrela/fogo): isola o personagem numa camada.
  final hasTint = tint != null;
  if (hasTint) {
    final w = height * 1.7;
    c.saveLayer(
      Rect.fromLTWH(-w / 2, -height * 1.15, w, height * 1.25),
      Paint()..colorFilter = tint,
    );
  }

  c.scale(squashX, squashY);

  if (rotation != 0) {
    // Gira em torno do centro do rosto (não dos pés).
    const faceCenterY = 84.0;
    final cy = -(designFeetY - faceCenterY) * s;
    c.translate(0, cy);
    c.rotate(rotation);
    c.translate(0, -cy);
  }

  c.scale(s);
  c.translate(-designFeetX, -designFeetY);

  _paintFaceGuy(c, tick, face);

  if (hasTint) c.restore();
  c.restore();
}

// Oval do rosto no espaço de design. Grande o suficiente para encostar melhor
// nos braços e descer um pouco por cima da bermuda, sem aro visual.
const Rect _faceOval = Rect.fromLTWH(10, -2, 180, 194);

final Paint _fill = Paint()
  ..style = PaintingStyle.fill
  ..isAntiAlias = true;
final Paint _outline = Paint()
  ..style = PaintingStyle.stroke
  ..strokeJoin = StrokeJoin.round
  ..strokeCap = StrokeCap.round
  ..color = Pal.black
  ..isAntiAlias = true;

void _paintFaceGuy(Canvas c, double tick, ui.Image? face) {
  final armSwing = sin(tick * 2 * pi) * 4;
  final legSwing = sin(tick * 2 * pi) * 3;

  _drawArms(c, armSwing);
  _drawLegsAndShoes(c, legSwing);
  _drawShorts(c);
  _drawHead(c, face, tick);
}

void _drawArms(Canvas c, double swing) {
  // Braços saem das laterais do rosto, terminando em luvas brancas.
  for (final side in const [-1, 1]) {
    final dir = side.toDouble();
    final shoulder = Offset(100 + dir * 60, 96);
    final hand = Offset(100 + dir * 96, 120 + (dir > 0 ? swing : -swing));

    _outline
      ..color = Pal.black
      ..strokeWidth = 16;
    c.drawLine(shoulder, hand, _outline); // contorno
    _outline
      ..color = Pal.red
      ..strokeWidth = 10;
    c.drawLine(shoulder, hand, _outline); // manga vermelha

    // Luva branca.
    _fill.color = Pal.white;
    c.drawCircle(hand, 13, _fill);
    _outline
      ..color = Pal.black
      ..strokeWidth = 3;
    c.drawCircle(hand, 13, _outline);
    _fill.color = const Color(0x55000000);
    c.drawCircle(hand + Offset(dir * 3, 4), 4, _fill);
  }
}

void _drawLegsAndShoes(Canvas c, double swing) {
  for (final side in const [-1, 1]) {
    final dir = side.toDouble();
    final hip = Offset(100 + dir * 20, 182);
    final ankle = Offset(100 + dir * 24, 210 + (dir > 0 ? swing : -swing));

    // Perninha (contorno + pele).
    _outline
      ..color = Pal.black
      ..strokeWidth = 15;
    c.drawLine(hip, ankle, _outline);
    _outline
      ..color = Pal.skin
      ..strokeWidth = 9;
    c.drawLine(hip, ankle, _outline);

    // Tênis (cápsula marrom com sola clara).
    final shoe = Rect.fromCenter(
      center: Offset(ankle.dx + dir * 6, ankle.dy + 8),
      width: 34,
      height: 20,
    );
    final shoeRR = RRect.fromRectAndRadius(shoe, const Radius.circular(9));
    _fill.color = Pal.brown;
    c.drawRRect(shoeRR, _fill);
    _outline
      ..color = Pal.black
      ..strokeWidth = 3;
    c.drawRRect(shoeRR, _outline);
    _fill.color = Pal.white;
    c.drawRect(
      Rect.fromLTWH(shoe.left + 2, shoe.bottom - 6, shoe.width - 4, 4),
      _fill,
    );
  }
}

void _drawShorts(Canvas c) {
  // Calção azul logo abaixo do rosto (na área do queixo).
  final shorts = RRect.fromRectAndCorners(
    const Rect.fromLTWH(58, 150, 84, 42),
    topLeft: const Radius.circular(10),
    topRight: const Radius.circular(10),
    bottomLeft: const Radius.circular(14),
    bottomRight: const Radius.circular(14),
  );
  _fill.color = Pal.blue;
  c.drawRRect(shorts, _fill);
  _outline
    ..color = Pal.black
    ..strokeWidth = 4;
  c.drawRRect(shorts, _outline);

  // Vinco central entre as pernas + botões dourados.
  _outline
    ..color = const Color(0x55000000)
    ..strokeWidth = 3;
  c.drawLine(const Offset(100, 176), const Offset(100, 192), _outline);
  _fill.color = Pal.yellow;
  c.drawCircle(const Offset(80, 162), 4, _fill);
  c.drawCircle(const Offset(120, 162), 4, _fill);
}

void _drawHead(Canvas c, ui.Image? face, double tick) {
  c.save();
  c.clipPath(Path()..addOval(_faceOval));
  if (face != null) {
    c.drawImageRect(
      face,
      Rect.fromLTWH(0, 0, face.width.toDouble(), face.height.toDouble()),
      _faceOval,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
  } else {
    _drawNoSignal(c, tick);
  }
  c.restore();
}

void _drawNoSignal(Canvas c, double tick) {
  // Chuvisco animado de TV antiga enquanto não há rosto. Mantém um tom verde
  // para combinar com o chroma, mas deixa o ruído bem evidente.
  final frame = (tick * 36).floor();
  final rnd = Random(frame);

  _fill.color = const Color(0xFF06180B);
  c.drawRect(_faceOval, _fill);

  // Faixas horizontais que "varrem" a tela.
  for (var i = 0; i < 5; i++) {
    final y =
        _faceOval.top + ((tick * 95 + i * 37) % (_faceOval.height + 30)) - 15;
    _fill.color = i.isEven ? const Color(0x663EFF7A) : const Color(0x55FFFFFF);
    c.drawRect(
      Rect.fromLTWH(_faceOval.left, y, _faceOval.width, 3 + (i % 2) * 3),
      _fill,
    );
  }

  // Linhas de varredura.
  for (var y = _faceOval.top; y < _faceOval.bottom; y += 7) {
    _fill.color = const Color(0x30000000);
    c.drawRect(Rect.fromLTWH(_faceOval.left, y, _faceOval.width, 2), _fill);
  }

  // Ruído grosso preto/branco/verde, mudando a cada frame.
  for (var i = 0; i < 260; i++) {
    final x = _faceOval.left + rnd.nextDouble() * _faceOval.width;
    final y = _faceOval.top + rnd.nextDouble() * _faceOval.height;
    final w = 1.5 + rnd.nextDouble() * 5;
    final h = 1.0 + rnd.nextDouble() * 3;
    final palette = rnd.nextInt(5);
    _fill.color = switch (palette) {
      0 => const Color(0xDDFFFFFF),
      1 => const Color(0xCC111111),
      2 => const Color(0xCC5CFF89),
      3 => const Color(0xAA8E8E8E),
      _ => const Color(0xCC001F0A),
    };
    c.drawRect(Rect.fromLTWH(x, y, w, h), _fill);
  }

  // Uma faixa mais forte piscando, para não parecer textura estática.
  final glitchY = _faceOval.top + (rnd.nextDouble() * _faceOval.height);
  _fill.color = const Color(0xAAFFFFFF);
  c.drawRect(
    Rect.fromLTWH(_faceOval.left, glitchY, _faceOval.width, 2),
    _fill,
  );
}
