import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'palette.dart';

/// Constroi uma ui.Image a partir de um mapa de pixels em texto.
/// Cada caractere indexa uma cor na paleta; '.' é transparente.
Future<ui.Image> _build(List<String> rows) {
  final h = rows.length;
  final w = rows[0].length;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final paint = Paint();
  for (var y = 0; y < h; y++) {
    final row = rows[y];
    for (var x = 0; x < w; x++) {
      final color = _palette[row[x]];
      if (color == null) continue;
      paint.color = color;
      canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), paint);
    }
  }
  return rec.endRecording().toImage(w, h);
}

const Map<String, Color> _palette = {
  'R': Pal.red,
  'D': Pal.darkRed,
  'S': Pal.skin,
  'B': Pal.blue,
  'H': Pal.brown,
  'T': Pal.tan,
  'Y': Pal.yellow,
  'O': Pal.darkGold,
  'K': Pal.black,
  'W': Pal.white,
};

const _playerJump = [
  '......RRRRRR....',
  '....RRRRRRRRRR..',
  '....HHHSSSKS....',
  '...HSHSSSSKSS...',
  '...HSHHSSSSKSSS.',
  '...HHSSSSSHHHH..',
  '.....SSSSSSS....',
  'SS..RRRBBRRR..SS',
  'SS.RRRBBBBRRR.SS',
  '.SSRRBBBBBBRRSS.',
  '...RBBYBBBYBBR..',
  '....BBBBBBBB....',
  '....BBB..BBB....',
  '....BBB..BBB....',
  '...HHHH..HHHH...',
  '..HHHHH..HHHHH..',
];

const _playerFall = [
  '......RRRRRR....',
  '....RRRRRRRRRR..',
  '....HHHSSSKS....',
  '...HSHSSSSKSS...',
  '...HSHHSSSSKSSS.',
  '...HHSSSSSHHHH..',
  '.....SSSSSSS....',
  '....RRRBBRRR....',
  '...RRRBBBBRRR...',
  '...RRBBBBBBRR...',
  '..SSBBYBBYBBSS..',
  '....BBBBBBBB....',
  '....BBB..BBB....',
  '....BBB..BBB....',
  '...HHHH..HHHH...',
  '..HHHHH..HHHHH..',
];

const _goomba = [
  '.....HHHHHH.....',
  '...HHHHHHHHHH...',
  '..HHHHHHHHHHHH..',
  '.HHWWKHHHHKWWHH.',
  '.HHWWKHHHHKWWHH.',
  'HHHHHHHHHHHHHHHH',
  'HHHHHHHHHHHHHHHH',
  '.HHHHHHHHHHHHHH.',
  '..TTTTTTTTTTTT..',
  '..TTKKKKKKKKTT..',
  '...TTTTTTTTTT...',
  '...KKKK..KKKK...',
  '..KKKKK..KKKKK..',
];

const _spiky = [
  '..W.....W.....W.',
  '.WWW...WWW...WWW',
  '.RRRRRRRRRRRRRR.',
  'RRRRDDRRRRDDRRRR',
  'RRRRRRRRRRRRRRRR',
  'RRRRRRRRRRRRRRRR',
  '.RRRRRRRRRRRRRR.',
  '..TTTTTTTTTTTT..',
  '..TKKTTTTTTKKT..',
  '..TTTTTTTTTTTT..',
  '...KKK....KKK...',
  '..KKKK....KKKK..',
];

const _mushroom = [
  '.....RRRRRR.....',
  '...RRRRRRRRRR...',
  '.RRWWWRRRRWWWRR.',
  '.RRWWWWRRWWWWRR.',
  'RRRWWWWRRWWWWRRR',
  'RRRRWWRRRRWWRRRR',
  'RRRRRRRRRRRRRRRR',
  '.RRRRRRRRRRRRRR.',
  '..WWWWWWWWWWWW..',
  '..WWKKWWWWKKWW..',
  '..WWKKWWWWKKWW..',
  '..WWWWWWWWWWWW..',
  '...WWWWWWWWWW...',
];

const _star = [
  '.......YY.......',
  '.......YY.......',
  '......YYYY......',
  '......YYYY......',
  'YYYYYYYYYYYYYYYY',
  '.YYYYYYYYYYYYYY.',
  '..YYYYYYYYYYYY..',
  '...YYKYYYYKYY...',
  '...YYYYYYYYYY...',
  '..YYYYYYYYYYYY..',
  '..YYYYY..YYYYY..',
  '.YYYY......YYYY.',
  '.YY..........YY.',
];

const _coin = [
  '.....YYYYYY.....',
  '...YYYYYYYYYY...',
  '..YYYOOOOOOYYY..',
  '..YYOYYYYYYOYY..',
  '.YYYOYYYYYYOYYY.',
  '.YYYOYYYYYYOYYY.',
  '.YYYOYYYYYYOYYY.',
  '.YYYOYYYYYYOYYY.',
  '.YYYOYYYYYYOYYY.',
  '.YYYOYYYYYYOYYY.',
  '..YYOYYYYYYOYY..',
  '..YYYOOOOOOYYY..',
  '...YYYYYYYYYY...',
  '.....YYYYYY.....',
];

/// Sprites pixel-art gerados em tempo de carga (sem assets binários).
class Sprites {
  late final ui.Image playerJump;
  late final ui.Image playerFall;
  late final ui.Image goomba;
  late final ui.Image spiky;
  late final ui.Image mushroom;
  late final ui.Image star;
  late final ui.Image coin;

  Future<void> load() async {
    playerJump = await _build(_playerJump);
    playerFall = await _build(_playerFall);
    goomba = await _build(_goomba);
    spiky = await _build(_spiky);
    mushroom = await _build(_mushroom);
    star = await _build(_star);
    coin = await _build(_coin);
  }
}

final Paint pixelPaint = Paint()..filterQuality = FilterQuality.none;

/// Desenha um sprite ancorado no centro-inferior (pés), com altura em pixels
/// virtuais e fatores opcionais de squash/stretch e espelhamento.
void drawSprite(
  Canvas c,
  ui.Image img,
  Offset feet,
  double height, {
  double scaleX = 1,
  double scaleY = 1,
  bool flipX = false,
  Paint? paint,
}) {
  final aspect = img.width / img.height;
  final h = height * scaleY;
  final w = height * aspect * scaleX;
  c.save();
  c.translate(feet.dx, feet.dy);
  if (flipX) c.scale(-1, 1);
  c.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    Rect.fromLTWH(-w / 2, -h, w, h),
    paint ?? pixelPaint,
  );
  c.restore();
}
