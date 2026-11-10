# Radial

Utilitário nativo para macOS 26 ou superior, em Swift, SwiftUI e AppKit. Sem dependências externas.

## Executar

1. Abra `Radial.xcodeproj` no Xcode.
2. Selecione o esquema **Radial** e o destino **My Mac**.
3. Pressione **⌘R**.

## Gesto global

1. Clique em **Ativar gesto global**.
2. Autorize **Radial** em **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade**. Há um botão na tela para abrir esses ajustes.
3. Volte ao Radial e clique em **Ativar gesto global** novamente.
4. Sobre outro app, segure o botão configurado sem arrastar (padrão: botão direito por 300 ms). A roda aparece perto do ponto pressionado.
5. Aponte para um setor e solte o botão para ativar o app. Pode mover além da borda da roda.
6. Volte à parte superior do centro, solte sem mover ou aperte **Esc** para cancelar.

Um clique rápido do botão configurado é encaminhado ao aplicativo original ao soltar. Um arrasto que ultrapassa 8 pontos antes do tempo de abertura é encaminhado ao app original. Durante um clique curto, o início fica retido até distinguir clique de gesto; isso pode ser percebido em apps com uso intenso do botão direito.

A roda abre centralizada na posição em que o gesto começou, inclusive nos cantos e nas bordas. Seu centro não é deslocado para dentro da tela; nessas posições, parte da roda e de suas ações pode ficar fora do monitor. Soltar sem mover continua cancelando. Ela não ativa o Radial ao aparecer.

**Desativar gesto** devolve o botão direito ao comportamento normal. O menu do Radial na barra de menus permite desativar, visualizar e sair, mesmo com a janela principal fechada. O app salva a última escolha: se o gesto estava ativo, tenta restaurá-lo ao reabrir, inclusive após recompilar. Sair pelo menu não desativa essa preferência. Na primeira execução, ative o gesto uma vez. Se faltar Acessibilidade, o app mostra o estado pendente e tenta novamente quando você volta dos Ajustes, sem abrir diálogos automaticamente. A assinatura ad hoc ainda pode exigir nova autorização do macOS após uma recompilação.

## Prévia

A janela principal exibe até oito aplicativos abertos, em ordem alfabética. Passe o mouse pela roda e clique em um setor para ativar o aplicativo. **Atualizar aplicativos** atualiza essa lista. A roda global atualiza a lista toda vez que abre. A troca de app usa Launch Services com ativação em primeiro plano e reaproveita a instância existente, para funcionar também quando o Radial está em segundo plano. Falhas retornadas pelo macOS aparecem na tela principal.

**Prévia flutuante** mostra o painel por três segundos, sem exigir a permissão global. Essa prévia é apenas visual e não captura cliques.

## Arquivos

- `RadialApp.swift`: entrada, janela principal e menu na barra do macOS.
- `ContentView.swift`: prévia interativa, ativação e estado do gesto.
- `WheelView.swift`: desenho compartilhado da roda e material Liquid Glass nativo.
- `WheelGeometry.swift`: seleção por direção e posicionamento em monitores.
- `GestureController.swift`: captura global, temporização, encaminhamento de clique/arrasto, cancelamento e painel flutuante.
- `RunningApps.swift`: consulta e ativação dos aplicativos via AppKit.

O App Sandbox foi desativado para permitir a interceptação global. A versão de desenvolvimento usa assinatura ad hoc local. Distribuição e assinatura Developer ID ainda não foram configuradas.

## Verificação

Compilar no Xcode com **⌘B**. As verificações de geometria podem ser executadas na pasta do projeto:

```sh
xcrun swiftc Radial/WheelGeometry.swift Checks/main.swift -o /tmp/radial-geometry-check
/tmp/radial-geometry-check
```

As verificações cobrem as direções de um a oito apps, centro de cancelamento, seleção além da borda, lista vazia e monitores com coordenadas negativas.

Para validar a integração após conceder Acessibilidade, testar: clique direito rápido no Finder, arrasto direito antes do prazo, segurar e escolher um app, soltar sem mover, retornar ao centro, cancelar com Esc e tentar nas bordas de cada monitor. A captura global depende dessa permissão e não é coberta pelas verificações de geometria.

Verificação da preferência e do encerramento do gesto, com domínio de preferências isolado e sem pedir permissão:

```sh
xcrun swiftc Radial/KeyboardShortcut.swift Radial/Localization.swift Radial/AppMemory.swift Radial/AppScriptActions.swift Radial/RunningApps.swift Radial/WheelView.swift Radial/WheelGeometry.swift Radial/AppExceptions.swift Radial/WheelPreferences.swift Radial/AppFavorites.swift Radial/WheelInteraction.swift Radial/GestureController.swift Radial/ContentView.swift Checks/GestureLifecycle/main.swift -o /tmp/radial-gesture-lifecycle-check
/tmp/radial-gesture-lifecycle-check
```

## Exceções por aplicativo

Na janela principal, abra **Exceções por aplicativo**. Use **Adicionar app aberto** ou **Escolher aplicativo…** para selecionar um `.app` instalado, mesmo que esteja fechado. O botão de menos remove uma exceção. As alterações são aplicadas imediatamente e persistem entre execuções.

Quando um app da lista está em primeiro plano, o clique, arrasto e soltura originais do botão configurado passam diretamente para ele, sem atraso nem abertura da roda. A regra vale para toda a duração daquele pressionamento, mesmo se o foco mudar. A exceção usa o identificador do aplicativo e não impede escolhê-lo como destino da roda a partir de outro app.

Verificação das exceções, sem instalar captura global nem enviar eventos ao sistema:

```sh
xcrun swiftc Radial/KeyboardShortcut.swift Radial/Localization.swift Radial/AppMemory.swift Radial/AppScriptActions.swift Radial/RunningApps.swift Radial/WheelView.swift Radial/WheelGeometry.swift Radial/AppExceptions.swift Radial/WheelPreferences.swift Radial/AppFavorites.swift Radial/WheelInteraction.swift Radial/GestureController.swift Radial/ContentView.swift Checks/AppExceptions/main.swift -o /tmp/radial-exceptions-check
/tmp/radial-exceptions-check
```

## Preferências

Abra **Preferências** na janela principal, no menu da barra de menus ou com **⌘,**.

- **Tamanho:** de 260 a 520 pontos; padrão de 380. O diâmetro é adaptado para monitores pequenos; as áreas de seleção e cancelamento acompanham o tamanho, mantendo o centro no ponteiro. A prévia na janela principal é limitada a 280 pontos para caber; **Prévia flutuante** mostra o tamanho real.
- **Tempo para abrir:** de 150 a 1000 ms; padrão de 300 ms.
- **Tempo para revelar ações:** de 150 a 1500 ms, com padrão de 650 ms. Vale para a prévia e a roda flutuante, a partir da próxima seleção de app.
- **Botão:** esquerdo, direito, do meio ou laterais 4 e 5; padrão de botão direito. A numeração dos botões laterais depende do mouse e de eventuais remapeamentos.

As escolhas são salvas automaticamente e valem para os próximos gestos. Alterar o botão durante um pressionamento mantém o botão original até soltar, preservando o par de eventos. **Restaurar padrão** redefine somente essas três opções e mantém as exceções e a ativação global.

Verificação de preferências, seleção redimensionada e encaminhamento dos cinco botões, usando eventos capturados em memória:

```sh
xcrun swiftc Radial/KeyboardShortcut.swift Radial/Localization.swift Radial/AppMemory.swift Radial/AppScriptActions.swift Radial/RunningApps.swift Radial/WheelView.swift Radial/WheelGeometry.swift Radial/AppExceptions.swift Radial/WheelPreferences.swift Radial/AppFavorites.swift Radial/WheelInteraction.swift Radial/GestureController.swift Radial/ContentView.swift Checks/Preferences/main.swift -o /tmp/radial-preferences-check
/tmp/radial-preferences-check
```

## Preservar Acessibilidade entre compilações

A preferência de ativação e a autorização do macOS são independentes. Com assinatura ad hoc, a identidade depende da compilação; salvar a preferência não preserva a autorização ao alterar o código.

Para desenvolvimento com identidade estável:

1. No Xcode, abra **Settings → Apple Accounts** e adicione sua conta Apple.
2. Selecione a conta/equipe e abra **Manage Certificates…**. Crie um certificado **Apple Development** caso ainda não exista.
3. Copie `Config/Signing.local.xcconfig.example` para `Config/Signing.local.xcconfig` e substitua `YOUR_TEAM_ID` pelo Team ID da conta/equipe. Esse arquivo é ignorado pelo Git. Nenhuma chave privada deve ser colocada nele.
4. Execute pelo mesmo projeto no Xcode. Confira que **Signing & Capabilities → Signing Certificate** mostra Apple Development.
5. Autorize essa versão assinada em Acessibilidade uma vez. Use a mesma identidade, bundle identifier e cópia do app nas próximas compilações.

`Config/Signing.xcconfig` inclui a configuração local automaticamente. Sem ela, o projeto mantém a assinatura ad hoc para continuar compilando, com a limitação de autorização acima. As compilações de verificação feitas com `CODE_SIGNING_ALLOWED=NO` validam o código, mas não a assinatura nem a persistência da autorização. A criação do certificado e a autorização precisam ser concluídas na conta/macOS do usuário.

## Favoritos em posições fixas

Abra **Preferências → Favoritos** e clique em uma das oito posições da roda. O painel abaixo permite escolher ou trocar o aplicativo, ajustar sua disponibilidade e remover o favorito. A roda mostra os ícones nas direções em que aparecerão no gesto; posições livres exibem **Automático**. Você pode escolher um app aberto pelo menu ou usar **Escolher aplicativo…** para selecionar um `.app` instalado. **Remover favorito** libera a posição para preenchimento automático. Para reorganizar, arraste um favorito até outro setor: uma posição livre recebe o app; uma posição ocupada troca os dois favoritos de lugar, preservando a disponibilidade de cada um. O setor de destino recebe um destaque durante o arrasto. Soltar no centro, fora da roda ou cancelar o arrasto não altera as posições. As ações de acessibilidade de cada favorito também permitem escolher uma direção de destino.

Com pelo menos um favorito, a roda mantém oito setores fixos, começando no topo e seguindo no sentido horário. Os favoritos aparecem com uma estrela. Cada um pode usar **Sempre na roda** (aparece fechado e pode ser aberto pela roda) ou **Só quando aberto** (só ocupa sua direção enquanto estiver em execução; fechado, libera a posição para outros apps). Os espaços livres recebem os outros apps abertos em ordem alfabética, sem repetir favoritos. Setores sem aplicativo não selecionam nada. Sem favoritos, a roda volta a se ajustar à quantidade de apps abertos.

Escolher o mesmo app em outra direção move o favorito para lá. As posições são salvas automaticamente e aplicadas na próxima abertura da roda. A prévia na janela principal atualiza ao editar; uma roda global já aberta preserva seus alvos até fechar. Se um app favorito for removido do Mac, sua posição permanece reservada e uma tentativa de abri-lo informa o erro.

Verificação de layout, persistência, favoritos fechados, reposicionamento e estabilidade durante o gesto:

```sh
xcrun swiftc Radial/KeyboardShortcut.swift Radial/Localization.swift Radial/AppMemory.swift Radial/AppScriptActions.swift Radial/RunningApps.swift Radial/WheelView.swift Radial/WheelGeometry.swift Radial/AppExceptions.swift Radial/WheelPreferences.swift Radial/AppFavorites.swift Radial/WheelInteraction.swift Radial/GestureController.swift Radial/ContentView.swift Checks/Favorites/main.swift -o /tmp/radial-favorites-check
/tmp/radial-favorites-check
```

A disponibilidade é configurada no painel da posição selecionada na roda. A escolha é salva e acompanha o app quando você o move para outra posição. Favoritos existentes continuam em **Sempre na roda** ao atualizar. Com favoritos configurados, os oito setores são mantidos mesmo quando todos os favoritos condicionais estão fechados. Se um favorito em **Só quando aberto** encerrar durante um gesto, a seleção não o relança.

## Fechar um app pela roda

Mantenha o ponteiro sobre um setor de app em execução pelo **Tempo para revelar ações** definido nas Preferências (650 ms por padrão). Surge um setor curvo externo na mesma direção do app, com ícone e o texto **Fechar**. O setor forma uma segunda camada da roda, separada por um pequeno intervalo. Mova o mouse para fora, na mesma direção, até essa ação e solte o botão do gesto para solicitar o encerramento. Na prévia da janela principal, clique na ação.

A ação mantém o app de origem ao cruzar o intervalo entre a roda e o setor externo. Apontar para outro app na roda remove o setor de fechamento imediatamente e inicia uma nova espera. Quando outro aplicativo ganha foco no macOS, o gesto global é cancelado e a prévia limpa a ação e seus temporizadores. O nome completo fica disponível na descrição de acessibilidade e na ajuda do setor. Aguardar o tempo configurado sobre outro app substitui o alvo. Voltar com o ponteiro ao centro ou apontar para um setor vazio remove imediatamente o setor externo e cancela a espera para mostrá-lo. Soltar no centro, fora da faixa **Abrir**, continua cancelando; soltar sobre outro setor continua selecionando normalmente. Revelar a ação, sozinho, não fecha nada. Esc cancela o gesto e limpa a ação. Favoritos fechados e o Finder não recebem ação de encerramento. O Finder continua disponível para seleção, mas seu identificador é bloqueado também na função de encerramento, incluindo ações de acessibilidade.

O fechamento usa o pedido normal de encerramento do macOS, sem forçar. O app pode pedir para salvar alterações ou cancelar a saída. Uma margem em toda a volta da roda acomoda a ação em qualquer direção. Perto das bordas, essa ação também pode ficar parcialmente fora da tela. A margem e o setor acompanham o tamanho configurado. A área clicável usa exatamente o mesmo arco do desenho; o intervalo e a roda principal não acionam o fechamento.

Verificação sem encerrar aplicativos reais (as solicitações de saída são simuladas):

```sh
xcrun swiftc Radial/KeyboardShortcut.swift Radial/Localization.swift Radial/AppMemory.swift Radial/AppScriptActions.swift Radial/RunningApps.swift Radial/WheelView.swift Radial/WheelGeometry.swift Radial/AppExceptions.swift Radial/WheelPreferences.swift Radial/AppFavorites.swift Radial/WheelInteraction.swift Radial/GestureController.swift Radial/ContentView.swift Checks/CloseAction/main.swift -o /tmp/radial-close-check
/tmp/radial-close-check
```

## Memória do aplicativo selecionado

Com **Mostrar consumo de RAM** ativado em **Preferências → Geral → Aparência**, o centro da roda mostra **RAM ≈ …** ao apontar para um aplicativo em execução, tanto na prévia interativa quanto no gesto global. A opção vem desativada por padrão. A primeira consulta ocorre ao selecionar; o valor atualiza a cada três segundos enquanto a seleção permanecer visível. A consulta roda fora da thread da interface e é cancelada ao trocar de seleção ou dispensar a roda. Favoritos fechados não exibem consumo; falhas de consulta mostram **RAM indisponível**.

A métrica usa `proc_pid_rusage` e `ri_phys_footprint`, sem comandos de terminal nem permissões adicionais. Soma o processo principal, processos do mesmo usuário cujo executável está dentro do bundle e seus descendentes, sem repetir PIDs. É uma estimativa: memória compartilhada pode ser contada em vários processos, serviços externos podem ficar de fora e o valor pode diferir do Monitor de Atividade. A ajuda do valor informa quantos processos foram consultados e indica quando algum processo identificado não pôde ser lido.

Verificação de agrupamento de auxiliares, falhas de consulta e leitura real do próprio processo:

```sh
xcrun swiftc Radial/Localization.swift Radial/AppMemory.swift Checks/Memory/main.swift -o /tmp/radial-memory-check
/tmp/radial-memory-check
```

## App em segundo plano e acesso pelo centro

O Radial inicia sem abrir a janela principal e sem ícone no Dock. Ele permanece acessível pelo ícone na barra de menus, cuja opção **Abrir Radial** mostra a janela principal. Fechar essa janela mantém o app e o gesto global em execução.

Quando nenhum aplicativo está selecionado, o centro da roda mantém **Escolha um app**. A faixa inferior de 30% do círculo central contém **Abrir**, com um ícone de janela. Aponte para essa faixa e solte o botão do gesto para abrir o Radial. Na prévia, clique nela. A área ganha destaque ao ser selecionada; o restante do centro continua cancelando. A geometria acompanha o tamanho da roda.

O Radial está disponível em inglês e português. Por padrão, segue os idiomas preferidos do macOS, com inglês como idioma de fallback. Em Preferências → Geral → Idioma, escolha Seguir o sistema, English ou Português. Reabra o Radial após alterar o idioma.

Ao alterar o idioma nas preferências, o app oferece **Reiniciar agora** ou **Depois**. A reinicialização mantém as preferências e o estado salvo do gesto global; se o macOS não conseguir abrir a nova instância, o app atual permanece aberto e mostra o erro.

## Iniciar com o macOS

Em **Preferências → Geral → Inicialização**, ative **Iniciar com o macOS** para abrir o Radial em segundo plano ao iniciar sessão. A opção usa o registro nativo de Itens de Início (`SMAppService.mainApp`), e não abre a janela principal nem adiciona um ícone ao Dock. O gesto global mantém seu estado salvo.

Se o sistema solicitar aprovação, a seção mostra o estado pendente e o botão **Abrir Itens de Início**. O estado é consultado novamente ao voltar ao app, respeitando alterações feitas nos Ajustes do Sistema. Desativar a opção remove o registro e mantém o Radial aberto na sessão atual. A opção só altera o sistema quando acionada pelo usuário; restaurar as preferências da roda não muda esse registro.

Os testes de preferências simulam os estados do serviço, incluindo falhas e aprovação pendente, sem alterar os Itens de Início reais.

## Prévia do tempo de abertura

A opção **Preferências → Geral → Gesto de abertura → Mostrar contagem ao segurar** vem desativada por padrão e é salva automaticamente. **Restaurar padrão** também a desativa. Quando ativada, ao segurar o botão configurado, um pequeno arco ao redor do ponteiro mostra o tempo restante até abrir a roda. Ele acompanha o prazo configurado no início do gesto. Um intervalo inicial de 60 ms evita piscar em cliques muito rápidos. Ao completar o prazo, o indicador dá lugar à roda; soltar antes, arrastar, pressionar Esc, mudar o foco ou desativar o gesto remove o indicador. Apps nas exceções não mostram a contagem. A prévia não recebe cliques nem ativa o Radial, e sua animação é liberada ao desaparecer.

## Revisão de processamento

A captura permanente não recebe movimentos do ponteiro sem botão pressionado. Um segundo observador de movimento, sem bloquear eventos, fica ativo somente enquanto a roda flutuante está visível; arrastos continuam na captura do gesto. A animação dos ícones e a consulta de RAM da roda flutuante são suspensas quando ela sai da tela. Fechar a janela principal libera sua prévia SwiftUI, recriada ao abrir novamente.

A leitura de RAM aguarda 150 ms de seleção estável para evitar varrer processos ao cruzar rapidamente os ícones. A coleta continua em segundo plano, com cancelamento, a cada 3 segundos enquanto houver seleção ativa. O agrupamento dos processos usa uma fila, e o buffer dos caminhos é reutilizado na amostragem.

O tamanho da prévia só publica alterações quando seu valor muda. Em um teste sintético de 100.000 atualizações com o mesmo tamanho, as notificações de alteração passaram de 100.000 para 1. Isso mede invalidações evitadas, não uma porcentagem de redução de CPU do app inteiro. Os testes de fechamento cobrem essa regressão; os testes de memória incluem uma árvore profunda de processos. O consumo real de CPU e energia requer medição no app assinado, fora do depurador, com uma carga de uso representativa.

## Indicador de app aberto

Uma bolinha abaixo do ícone identifica apenas favoritos em execução, tanto na roda principal quanto na configuração de favoritos. Apps sem posição favorita e favoritos fechados permanecem sem o indicador. O estado é atualizado ao abrir a roda e pelas notificações de abertura e encerramento do macOS, sem polling adicional e sem mudar as posições durante um gesto. Leitores de tela recebem o estado **Em execução** ou **Fechado** para o app selecionado.

## Atalho pelo teclado

Em **Preferências → Geral → Teclado**, use **Gravar atalho…**, pressione uma combinação com Command, Option ou Control e uma tecla, e confirme em **Salvar atalho**. Nenhum atalho é configurado por padrão. A combinação é salva automaticamente e pode ser desativada com **Remover** ou **Restaurar padrão**.

Segure o atalho para abrir a roda na posição do ponteiro, aponte para um app e solte a combinação para confirmar. Soltar sem mover ou voltar ao centro cancela; **Esc** também cancela. A ação **Fechar** e a área **Abrir Radial** funcionam como no gesto do mouse. As exceções por aplicativo são respeitadas. O atalho funciona independentemente da ativação do gesto pelo mouse, usando a mesma permissão de Acessibilidade. Não altera a preferência salva do gesto global.

O registro nativo do macOS detecta combinações indisponíveis e informa o erro nas preferências. Durante a gravação, o atalho atual fica suspenso. Sem atalho configurado, nenhum atalho global é registrado. Quando somente o teclado está ativado, a captura temporária de eventos é liberada ao fechar a roda.

## Janela principal e Dock

Ao abrir a janela principal, o Radial passa a aparecer no Dock e no Command-Tab, permanecendo acessível ao alternar para outro aplicativo. Minimizar mantém o ícone; solicitar a abertura novamente restaura a janela. Fechar a janela principal remove o ícone do Dock e mantém o app em segundo plano, com seus gestos e atalhos. A roda flutuante não altera a presença no Dock.


## Ações de reprodução

Com o Spotify ou o Música (Music) aberto, mantenha o ponteiro sobre o setor do app até aparecerem os controles na borda. Aponte para **Faixa anterior**, **Reproduzir/Pausar** ou **Próxima faixa** e solte o botão ou atalho usado para abrir a roda. Na prévia interativa, clique no controle. O ícone vermelho continua disponível para fechar o app.

Na primeira ação em cada app, o macOS pode pedir autorização para o Radial controlá-lo. Se a autorização tiver sido negada, veja **Ajustes do Sistema → Privacidade e Segurança → Automação**. O Radial lê os comandos do dicionário instalado e só mostra os controles definidos no perfil que estiverem disponíveis nessa versão do app.

Com a Automação autorizada, um indicador ▶ junto ao canto superior direito do ícone mostra que o Spotify ou o Música está reproduzindo. O estado é consultado enquanto a roda está visível. O indicador some quando o app pausa ou para.

## Ações do Xcode

Com um projeto ou workspace aberto no Xcode, mantenha o ponteiro no setor do app para revelar **Compilar**, **Executar**, **Testar** e **Parar**. A ação usa o workspace ativo no Xcode. Compilar, executar e testar também usam o esquema e o destino ativos. O macOS pode pedir autorização de Automação na primeira ação.

## Escolher uma janela

Quando o Radial encontra duas ou mais janelas para o mesmo app, inclusive em processos da mesma edição do IntelliJ, o setor ganha uma faixa externa de abas numeradas após o **Tempo para revelar ações** configurado. Aponte para uma aba para ver o título da janela no centro e as ações dela na faixa seguinte. Solte sobre a aba para trazer a janela à frente ou sobre uma ação para executá-la. **Fechar janela** solicita o fechamento da janela selecionada.

O seletor usa a permissão de **Acessibilidade** e só inclui janelas que o app expõe ao macOS. Se houver mais de três, role enquanto segura o gesto para trocar de página. Na prévia interativa, clique nas setas das abas. Soltar no intervalo entre as faixas ou pressionar Esc durante o gesto cancela.
