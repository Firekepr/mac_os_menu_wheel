# AppWheel

Utilitário nativo para macOS 26 ou superior, em Swift, SwiftUI e AppKit. Sem dependências externas.

## Executar

1. Abra `AppWheel.xcodeproj` no Xcode.
2. Selecione o esquema **AppWheel** e o destino **My Mac**.
3. Pressione **⌘R**.

## Gesto global

1. Clique em **Ativar gesto global**.
2. Autorize **AppWheel** em **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade**. Há um botão na tela para abrir esses ajustes.
3. Volte ao AppWheel e clique em **Ativar gesto global** novamente.
4. Sobre outro app, segure o botão direito por 300 ms sem arrastar. A roda aparece perto do ponto pressionado.
5. Aponte para um setor e solte o botão para ativar o app. Pode mover além da borda da roda.
6. Volte ao centro, solte sem mover ou aperte **Esc** para cancelar.

O clique direito rápido é encaminhado ao aplicativo original ao soltar. Um arrasto que ultrapassa 8 pontos antes dos 300 ms é encaminhado ao app original. Durante um clique curto, o início fica retido até distinguir clique de gesto; isso pode ser percebido em apps com uso intenso do botão direito.

A roda é posicionada dentro da área útil do monitor. Perto de uma borda, seu centro pode se deslocar. Soltar sem mover continua cancelando. Ela não ativa o AppWheel ao aparecer.

**Desativar gesto** devolve o botão direito ao comportamento normal. O menu do AppWheel na barra de menus permite desativar, visualizar e sair, mesmo com a janela principal fechada. O gesto inicia desativado a cada execução.

## Prévia

A janela principal exibe até oito aplicativos abertos, em ordem alfabética. Passe o mouse pela roda e clique em um setor para ativar o aplicativo. **Atualizar aplicativos** atualiza essa lista. A roda global atualiza a lista toda vez que abre. A troca de app usa Launch Services com ativação em primeiro plano e reaproveita a instância existente, para funcionar também quando o AppWheel está em segundo plano. Falhas retornadas pelo macOS aparecem na tela principal.

**Prévia flutuante** mostra o painel por três segundos, sem exigir a permissão global. Essa prévia é apenas visual e não captura cliques.

## Arquivos

- `AppWheelApp.swift`: entrada, janela principal e menu na barra do macOS.
- `ContentView.swift`: prévia interativa, ativação e estado do gesto.
- `WheelView.swift`: desenho compartilhado da roda e material Liquid Glass nativo.
- `WheelGeometry.swift`: seleção por direção e posicionamento em monitores.
- `GestureController.swift`: captura global, temporização, encaminhamento de clique/arrasto, cancelamento e painel flutuante.
- `RunningApps.swift`: consulta e ativação dos aplicativos via AppKit.

O App Sandbox foi desativado para permitir a interceptação global. A versão de desenvolvimento usa assinatura ad hoc local. Distribuição e assinatura Developer ID ainda não foram configuradas.

## Verificação

Compilar no Xcode com **⌘B**. As verificações de geometria podem ser executadas na pasta do projeto:

```sh
xcrun swiftc AppWheel/WheelGeometry.swift Checks/main.swift -o /tmp/appwheel-geometry-check
/tmp/appwheel-geometry-check
```

As verificações cobrem as direções de um a oito apps, centro de cancelamento, seleção além da borda, lista vazia e monitores com coordenadas negativas.

Para validar a integração após conceder Acessibilidade, testar: clique direito rápido no Finder, arrasto direito antes do prazo, segurar e escolher um app, soltar sem mover, retornar ao centro, cancelar com Esc e tentar nas bordas de cada monitor. A captura global depende dessa permissão e não é coberta pelas verificações de geometria.
