# SyncView — Galaxy Tab S9 Ultra como segunda tela do Mac

## Como funciona

```
Mac                                                      Galaxy Tab S9 Ultra
┌───────────────────────────────────────────┐           ┌──────────────────────────────┐
│ Monitor virtual 2960×1848 @ 120 Hz        │           │ Decodificador HEVC (hardware)│
│   (o macOS acha que é um monitor real)    │           │ baixa latência               │
│        ↓ ScreenCaptureKit (120 fps)       │  cabo USB │        ↓                     │
│ Encoder HEVC (Media Engine do M4 Pro)     │ ────────► │ Tela cheia 2960×1848, 120 Hz │
│        ↓ TCP 127.0.0.1:52020              │ adb       │ inclusive a área da câmera   │
│ Cliques/rolagem ◄──────────────────────── │ ◄──────── │ Toque e S Pen                │
└───────────────────────────────────────────┘           └──────────────────────────────┘
```

- **Resolução:** o Mac cria um monitor com a resolução nativa do tablet, 2960×1848. Por padrão ele usa o modo Retina "parece 1480×924", com a mesma densidade da tela do MacBook. Cada pixel do Mac vira exatamente um pixel do tablet.
- **120 Hz:** o monitor virtual roda a 120 Hz e a captura pede 120 fps. O app do tablet força o painel a 120 Hz.
- **Cabo:** o vídeo passa por um túnel `adb reverse` no cabo USB. Nada vai para a rede.
- **Estabilidade:**
  - O app do Mac recria o túnel a cada 2 s e o tablet reconecta sozinho.
  - Se o cabo soltar, o monitor virtual continua existindo por 30 s, então suas janelas não pulam para a tela do MacBook.
  - Um watchdog derruba e refaz a conexão se ela ficar 4 s em silêncio.

### O que já foi testado neste Mac (M4 Pro, macOS 27.2)

| Teste | Resultado |
|---|---|
| Monitor virtual 2960×1848 @ 120 Hz | ✅ criado, com os três modos HiDPI a 120 Hz |
| Encoder HEVC 2960×1848 no pior caso (tela inteira mudando a cada quadro) | ✅ 119,7 fps, ~16 ms de latência (p50) e ~29 ms (p99) |
| Encoder H.264 na mesma resolução | ⚠️ só ~92 fps, por isso fica limitado a 60 fps (é só um plano B) |
| Protocolo Mac ↔ cliente (HELLO, ping/pong) | ✅ |
| APK do tablet | ✅ compila |
| **Captura real a 120 fps + tablet de verdade** | ⏳ **falta testar.** Precisa da sua permissão de Gravação de Tela e do tablet plugado (passo 5) |

---

## 1. O que você precisa

- **Cabo USB‑C ↔ USB‑C de dados.** De preferência USB 3 (5 ou 10 Gbps), ligado **direto** numa porta do Mac, sem hub.
  - O cabo que vem com o tablet é **USB 2 (480 Mbps)**. Ele funciona, mas no limite.
  - **Cabo ruim = quedas.** Se o log do adb (`$TMPDIR/adb.501.log`) mostrar `read failed` ou `write failed`, os dados estão se corrompendo no cabo. O SyncView se recupera sozinho, mas a solução é trocar o cabo. Use um cabo USB‑C ↔ USB‑C **USB 3.2 Gen 2 (10 Gbps), Thunderbolt 4 ou USB4**, de até 1 m. Com o cabo certo, o menu do SyncView deixa de mostrar o aviso "Cabo USB 2.0".
  - Num link USB 2, o SyncView limita a qualidade a **50 Mbps** sozinho. Acima disso, o adb do tablet chega a travar e o tablet fica "offline". O menu avisa quando isso acontece.
  - Para usar "Alta (100)" ou "Máxima (200 Mbps)", use um cabo USB 3 (5 ou 10 Gbps).
- As ferramentas já ficaram instaladas neste Mac via Homebrew: `adb`, JDK 21, Gradle e Android SDK.

## 2. Preparar o tablet (uma vez só)

1. **Ativar o modo desenvolvedor:** Configurações › Sobre o tablet › Informações do software › toque **7 vezes** em *Número de compilação*.
2. Em Configurações › **Opções do desenvolvedor**, ative:
   - **Depuração USB**
   - **Desativar tempo limite de revogação de autorização adb.** Sem isso, o Android esquece seu Mac depois de 7 dias e pede autorização de novo.
3. **Ligar os 120 Hz:** Configurações › Tela › **Suavidade de movimento › Adaptável**.
   - Se ficar em "Padrão", o painel trava em 60 Hz. O app avisa na tela se for o caso.
4. *(Recomendado)* Desligue o **Economia de energia** enquanto usa como monitor.

## 3. Instalar (Mac + tablet)

1. Conecte o tablet no Mac pelo cabo.
2. No tablet, aparece **"Permitir depuração USB?"**. Marque **"Sempre permitir deste computador"** e toque em Permitir.
3. No Terminal:

```bash
cd ~/Documents/SyncView && ./instalar.sh
```

O script faz quatro coisas:
- compila o app do Mac e instala em `/Applications/SyncView.app`;
- instala `dist/SyncView-tablet.apk` no tablet;
- tira o app do tablet da otimização de bateria;
- abre o SyncView.

Se o tablet não estiver conectado, ele instala só o Mac. Nesse caso, rode de novo depois de plugar.

4. No tablet: Configurações › Aplicativos › **SyncView** › Bateria › **Irrestrito**. É uma garantia extra, além do que o script já faz.

## 4. Dar as permissões no Mac (uma vez só)

O SyncView aparece como um ícone na **barra de menus**, no canto superior direito. Ele não tem ícone no Dock.

1. **Gravação de Tela** (obrigatória):
   - Abra Ajustes do Sistema › Privacidade e Segurança › **Gravação de Tela e Áudio do Sistema**.
   - Ative o **SyncView**.
   - Depois, **saia do SyncView** (menu › Sair) e abra de novo pelo Launchpad ou por `/Applications`.
2. **Acessibilidade** (para o toque e a S Pen controlarem o mouse): Ajustes do Sistema › Privacidade e Segurança › **Acessibilidade** › ative o **SyncView**.

Enquanto faltar alguma permissão, o menu do SyncView mostra um item "⚠︎ Permitir…" que abre o painel certo.

> O app é assinado com um certificado local fixo, "SyncView Local Signing", criado por `mac/setup-signing.sh` num keychain próprio. Por isso as permissões continuam valendo quando você recompila. Se um dia o macOS voltar a dizer "sem permissão" com a chave ligada, rode `tccutil reset ScreenCapture com.syncview.mac`, reabra o app e conceda de novo.

## 5. Primeira conexão e conferência dos 120 Hz

1. Com o cabo plugado, o Mac abre o app no tablet sozinho. Se não abrir, toque no ícone **SyncView** no tablet.
2. A tela do tablet vira um monitor do Mac em 1–2 s.
3. **Posicione o monitor:** clique no ícone do SyncView › **Organizar monitores…** e arraste o tablet para o lado certo do MacBook. O macOS lembra essa posição nas próximas conexões.
4. **Confira os 120 Hz:**
   - No Mac: Ajustes › Monitores › selecione o tablet › *Taxa de atualização* deve mostrar **120 Hz**.
   - No tablet: **toque com 3 dedos** para abrir o menu do SyncView e toque em **Mostrar estatísticas**. Mexa uma janela ou role uma página. O ideal é:
     ```
     HEVC 2960x1848 · alvo 120 fps
     exibidos ~120 fps · tela 120 Hz
     ```
   - Com a tela parada, os fps caem para perto de 0. Isso é normal: o Mac só manda quadros quando algo muda.
   - O menu do SyncView no Mac também mostra fps e Mbps em tempo real.

### Diagnóstico automático (opcional)

Feche o SyncView antes. Depois rode:

```bash
open -n /Applications/SyncView.app --args --selftest
```

Durante 6 s o cursor vai girar sozinho num monitor de teste. Depois, veja o resultado:

```bash
grep selftest ~/Library/Logs/SyncView.log | tail -8
```

A linha `Pipeline: … ≈ N fps` mostra a captura de verdade de ponta a ponta. O esperado é perto de 120.

## 6. Uso no dia a dia

**Configure uma vez:** no menu do SyncView, ative **"Abrir ao iniciar sessão"**.

**Depois disso, todo dia:**
1. Desbloqueie o tablet.
2. Plugue o cabo.

O Mac detecta o tablet, abre o app nele e a imagem aparece em 1–2 s. As posições das janelas e do monitor ficam como você deixou.

Não precisa rodar `instalar.sh` de novo, nem dar permissões, nem aceitar a depuração USB outra vez. Isso só vale se o passo 2 foi feito com "Sempre permitir" e "Desativar tempo limite de revogação".

| Se… | Faça |
|---|---|
| O ícone do SyncView não está na barra de menus | Abra o SyncView pelo Launchpad |
| O tablet não abriu o app sozinho | Toque no ícone SyncView no tablet. Isso acontece, por exemplo, se o tablet estava bloqueado na hora de plugar |
| Quer encerrar | No tablet, **toque com 3 dedos** (ou faça o gesto de voltar) › **Sair do SyncView**. O monitor some do Mac na hora e as janelas voltam para o MacBook |
| Você fechou o app no tablet e quer voltar | Abra de novo pelo ícone SyncView no tablet |
| O cabo soltou | Replugue em até 30 s: o monitor continua no Mac esperando e as janelas não pulam |

### Gestos no tablet

| Gesto | Ação no Mac |
|---|---|
| Tocar com 1 dedo | Clique (2 toques rápidos = duplo clique) |
| Tocar e arrastar | Arrastar (mover janela, selecionar texto) |
| Arrastar com 2 dedos | Rolagem com inércia |
| Tocar com 2 dedos | Clique direito |
| S Pen pairando | Move o cursor |
| S Pen encostando | Clique ou arrasto. Com o botão lateral apertado, vira clique direito |
| Tocar com 3 dedos | Abre o **menu do SyncView** no tablet |
| Gesto de voltar (deslizar da borda lateral) | Também abre/fecha o menu |
| Deslizar da borda de baixo | Mostra as barras do Android (somem sozinhas) |

### Menu do SyncView no tablet

Abre com um toque de 3 dedos ou com o gesto de voltar. Tem quatro opções:
- **Voltar para a tela**;
- **Mostrar/ocultar estatísticas** (fps, Mbps, Hz, latência);
- **Reconectar**;
- **Sair do SyncView**, que fecha o app e avisa o Mac para remover o monitor na hora.

A tela de espera ("Aguardando o Mac…") também tem os botões **Reconectar** e **Sair do SyncView**.

### Menu do SyncView no Mac

- **Tamanho da interface:**
  - *Padrão (Retina)* = parece 1480×924, o mais nítido;
  - *Mais espaço* = 1776×1108;
  - *Máximo de espaço* = 1974×1232.
- **Qualidade:** 50, 100 (padrão) ou 200 Mbps. Suba se notar borrão ao rolar textos.
- **Codec:** HEVC, que dá 120 fps (padrão), ou H.264, até 60 fps, só como plano B.
- **Inverter direção da rolagem**, se ela parecer ao contrário.
- **Reconectar:** reinicia o adb e "repluga" o cabo por software (o tablet some e volta no USB em ~3 s). É o equivalente a tirar e colocar o cabo.
- **Abrir log** (`~/Library/Logs/SyncView.log`).

## 7. Solução de problemas

| Sintoma | Causa provável e o que fazer |
|---|---|
| Menu diz "Aguardando tablet no cabo USB…" | Depuração USB desligada, cabo só de carga ou hub no meio. Teste com `adb devices` no Terminal |
| "Autorize a depuração USB na tela do tablet" | Aceite o aviso no tablet, marcando "Sempre permitir" |
| "adb não encontrado" | Rode `brew install android-platform-tools` |
| Tablet mostra "Aguardando o Mac…" para sempre | SyncView fechado no Mac ou sem permissão de Gravação de Tela. Veja o menu e o log |
| Caiu sozinho; `adb devices` mostra **offline** ou nada | O link USB travou. O Mac resolve sozinho: reinicia o adb e "repluga" o cabo por software, e a imagem volta em ~10 s, sem as janelas saírem do lugar. Para forçar na hora, use **Reconectar** no menu |
| Quedas seguidas | O cabo está corrompendo dados. O SyncView reduz a taxa sozinho (50 → 35 → 25 → 15 Mbps) e volta a subir depois de 30 min estável. Depois de 3 tentativas sem sucesso, ele para de insistir e o menu pede para **tirar e colocar o cabo**. A solução definitiva é trocar o cabo |
| Como testar o cabo | Com o SyncView fechado, mande e traga 200 MB cinco vezes: `mkfile 200m /tmp/t.bin; for i in 1 2 3 4 5; do adb push /tmp/t.bin /data/local/tmp/t.bin && adb pull /data/local/tmp/t.bin /tmp/t2.bin \|\| break; done`. Um link bom faz tudo sem erro (~35 MB/s em USB 2, bem mais em USB 3). Se falhar com `read failed` ou o tablet sumir do `adb devices`, o cabo ou uma das portas (Mac ou tablet) está ruim: troque um de cada vez para achar qual |
| O app abriu numa janela pequena no tablet | O Samsung abriu em "janela pop-up". Toque em ⛶ (tela cheia) na barra da janela |
| Aviso "limitado a 60 Hz" no tablet | Suavidade de movimento › **Adaptável** |
| Estatísticas mostram "tela 60 Hz" | Economia de energia ligada, ou o tablet está esquentando e reduzindo a taxa |
| Imagem trava e volta após ~1 s | Cabo ruim ou porta frouxa. Troque de cabo/porta. O app se recupera sozinho |
| Menu mostra "quadros pulados" | O cabo não está dando conta. Use USB 3 ou baixe a Qualidade |
| Menu mostra "Cabo USB 2.0: qualidade limitada" | O link USB é de 480 Mbps. Funciona, mas troque por um cabo USB 3 para usar 100–200 Mbps |
| Toque não faz nada | Falta a permissão de Acessibilidade (passo 4) |
| Conflito com o Android Studio | Android Studio e Homebrew podem ter versões diferentes de `adb` brigando. Use uma só |
| Depois de recompilar, a imagem não aparece | Refaça as permissões do passo 4 |

## 8. Limitações conhecidas

- **Notch:** a câmera frontal do S9 Ultra cobre um pedacinho do topo, como o notch do MacBook. Isso é consequência de usar 100% do painel.
- **Cores em texto fino:** o vídeo usa crominância 4:2:0. Texto colorido muito fino pode ganhar uma leve franja de cor. Texto preto ou branco fica perfeito.
- **API privada:** o monitor virtual usa a API `CGVirtualDisplay`, a mesma do Sidecar, BetterDisplay e DeskPad. Uma atualização do macOS pode exigir ajuste no código.
- **Sem HDR e sem áudio.** O áudio continua saindo pelo Mac.
- **Latência:** o encoder mede ~16 ms. A latência total (captura → tablet) não foi medida, mas a estimativa é 25–40 ms. É ótimo para trabalho, mas não é Sidecar com fio.

## 9. Estrutura do projeto

```
SyncView/
├── instalar.sh              ← instala tudo
├── tools/make-icons.swift   ← gera os ícones (Mac e Android)
├── dist/SyncView-tablet.apk ← APK pronto
├── mac/                     ← app do Mac (Swift, barra de menus)
│   ├── build-app.sh         ← gera mac/build.noindex/SyncView.app (--install copia p/ /Applications)
│   ├── setup-signing.sh     ← certificado local fixo (permissões sobrevivem a recompilações)
│   └── Sources/SyncView/
│       ├── VirtualDisplay.swift   monitor virtual 120 Hz
│       ├── ScreenCapturer.swift   captura (ScreenCaptureKit)
│       ├── VideoEncoder.swift     HEVC/H.264 por hardware
│       ├── StreamServer.swift     TCP + watchdog
│       ├── ADBManager.swift       túnel USB e abertura do app no tablet
│       ├── InputInjector.swift    toque → mouse
│       └── Controller.swift       orquestra tudo
└── android/                 ← app do tablet (Kotlin, sem dependências)
    ├── build-apk.sh
    └── app/src/main/java/com/syncview/receiver/
        ├── MainActivity.kt   tela cheia, 120 Hz, estatísticas
        ├── StreamClient.kt   conexão + reconexão
        ├── VideoDecoder.kt   MediaCodec baixa latência
        └── TouchHandler.kt   gestos e S Pen
```
