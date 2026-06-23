# Super Maior World — Helix Jump Edition

Um Helix Jump com visual de Super Mario World (SNES), feito em **Flutter + Flame**.
Renderização pseudo-3D (projeção manual do cilindro no canvas 2D), funciona em
web e, futuramente, mobile (Android/iOS) sem mudanças de código.

## Como jogar

- **Arraste** (ou setas ← → / A-D) para girar a torre.
- Dê **dois toques rápidos** para usar um pulo extra no ar; ele recarrega ao quicar.
- **Arraste para baixo** para mergulhar girando. Goombas e Koopas só são derrotados assim; cair normalmente sobre eles causa dano.
- Pegue a **Flor de Fogo** e **arraste para cima** para lançar uma bola de fogo para cada lado.
- Caia pelos **vãos** das plataformas; evite os segmentos de **lava com espinhos**.
- Atravesse **3 andares sem quicar** para entrar no **MODO FOGO** e quebrar a próxima plataforma.
- Ataque **Goombas e Koopas girando** para ganhar pontos e quicar mais alto — os **espinhosos** continuam perigosos.
- **Koopas verdes e vermelhas** viram cascos em movimento após um ataque giratório; os cascos eliminam outros inimigos.
- **Cogumelo** = forma Super. **Flor** = poder de fogo. **Estrela** = invencível, quebra tudo por 8s e garante o próximo pouso em um andar seguro. **Moedas** = pontos.
- O recorde fica salvo no navegador.

## Rodar localmente

O Flutter SDK está em `E:\Diego\flutter` (adicione `E:\Diego\flutter\bin` ao PATH se quiser).

```powershell
$env:PATH = "E:\Diego\flutter\bin;$env:PATH"
flutter pub get
flutter run -d chrome            # modo desenvolvimento
flutter build web --release      # gera build/web para publicar
```

Para servir o build de produção:

```powershell
dart pub global activate dhttpd
dart pub global run dhttpd --path build/web --port 8077
# abra http://localhost:8077
```

## Estrutura

| Arquivo | Conteúdo |
| --- | --- |
| `lib/src/game.dart` | Loop do jogo, estados, física, colisões, pontuação |
| `lib/src/render.dart` | Renderizador pseudo-3D + cenário SMW + HUD + telas |
| `lib/src/model.dart` | Torre, andares, geração procedural, inimigos, itens |
| `lib/src/sprites.dart` | Pixel-art gerada por código (sem assets binários) |
| `lib/src/palette.dart` | Paleta de cores estilo SNES |

## Próximos passos (mobile)

```powershell
flutter create . --platforms=android,ios
flutter run -d <device>
```

O jogo já usa resolução virtual 480x854 com letterbox e controles de toque,
então roda em qualquer celular sem ajustes.
