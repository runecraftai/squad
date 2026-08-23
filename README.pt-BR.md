[English](README.md) | Português (Brasil)

<p align="center">
  <img alt="Squad — distro de agentes: fale com um agente, entregue com uma squad. O sargento de armas despacha operadores visíveis (sq-task-1 strike em andamento, sq-task-2 recon concluído, sq-task-3 strike na fila) que entregam um PR ou um relatório de recon ao comandante." src="assets/readme/hero.svg" width="100%" />
</p>

<p align="center">
  <a href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"><img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square" /></a>
</p>

## O que é

Rodar um agente de código é fácil. No momento em que você quer três tarefas de projeto em paralelo - correções, investigações, planos, auditorias - você vira um malabarista de abas: cuidando de sessões, copiando e colando contexto entre repositórios, esquecendo qual terminal tinha o teste quebrado.

O Squad inverte o modelo. Você conversa com um único agente - o **sargento de armas** - e ele comanda a squad para você: despachando operadores visíveis em um backend de sessão, dando a cada um um worktree git limpo, supervisionando-os até a conclusão e entregando PRs prontos, merges locais aprovados ou relatórios de recon independentes. Para unidades maiores, você pode ativar XOs persistentes: operadores que rodam a partir de bases Squad isoladas próprias, nesta máquina ou em outro host alcançável por SSH.

O Squad não é um modelo, não é um harness, não é uma skill, não é um servidor MCP e não é uma CLI. O Squad é uma **distro de agentes**: um diretório portátil de instruções, skills, ferramentas, políticas e convenções de estado que transforma um agente de propósito geral em um especializado. Não há aplicativo para instalar - o repositório clonado é a distro (`AGENTS.md`, skills do Squad empacotadas e scripts auxiliares que qualquer agente de código de terminal consegue seguir). Lançar um harness suportado dentro dele instancia seu agente - e torna você o comandante.

## Para quem é

Você alterna vários projetos ou repositórios ao mesmo tempo - correções, investigações, auditorias - e está cansado de cuidar de sessões, copiar contexto entre terminais e esquecer qual repositório tinha o teste quebrado. Você quer um único ponto de contato que despache workers visíveis, os supervise e lhe entregue PRs e relatórios prontos.

## Para quem não é

- Você quer que um único agente seja mais disciplinado e verificável - isso é uma preocupação por sessão, não no nível da unidade.
- Você tem um repositório e uma tarefa por vez.
- Você não está disposto a configurar um harness, autenticação GitHub e um backend de sessão.

## Como funciona

<p align="center">
  <img alt="Fluxo do Squad: o comandante conversa com o sargento de armas, que despacha operadores visíveis em worktrees FOB isolados e backends de sessão supervisionados; strikes entregam PRs ou merges locais aprovados, recons entregam relatórios, e a sentinela acorda o sargento apenas em eventos acionáveis." src="assets/readme/workflow.svg" width="100%" />
</p>

Você conversa com o agente. Ele encaminha cada pedido a um operador em seu próprio endpoint de sessão e worktree git, supervisiona a unidade com uma sentinela orientada a eventos que consome zero tokens, e traz PRs prontos, merges locais aprovados ou relatórios de recon. A sentinela dorme sobre a unidade e acorda o sargento só quando algo realmente precisa de você.

XOs opcionais estendem isso para XOs persistentes locais ou remotos de base inteira; perfis de despacho permitem direcionar qual harness cuida de qual tarefa; e o Relay opcional permite que a mesma unidade responda menções públicas no X e no Discord. `codex-app` ainda não é um backend de runtime - [docs/pt-BR/codex-app-backend.md](docs/pt-BR/codex-app-backend.md) é dono dessa fronteira.

A arquitetura completa - o motor de supervisão, isolamento de worktrees, XOs, perfis de despacho, modos de projeto, Relay opcional, unit sync e self-update - vive em [docs/pt-BR/architecture.md](docs/pt-BR/architecture.md).

## Começo rápido

### Requisitos

- Um harness de agente primário verificado: Claude Code, Grok, Pi, `pi-signed`, Codex ou OpenCode.
- Git e o GitHub CLI, autenticados via `gh auth login`.
- A CLI e as dependências do backend de runtime selecionado; tmux é o padrão de referência.

O agente detecta e oferece instalar as ferramentas suportadas que faltam depois que você aprova.

### Instalar e lançar

```sh
gh auth login
git clone https://github.com/runecraftai/squad
cd squad
```

Depois lance um dos harnesses co-primários; o AGENTS.md assume a partir daí:

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
# ou, quando o wrapper assinado estiver instalado
SQUAD_PI_HARNESS=pi-signed pi-signed
```

Para o Grok, `--trust` é necessário uma vez por clone para que os hooks do projeto e o turn-end guard carreguem; `/hooks-trust` dentro do Grok também funciona.
Para o Pi, aprove o prompt de confiança do projeto uma vez por clone no primeiro lançamento para que os arquivos versionados `.pi/extensions/*.ts` carreguem automaticamente.
O toggle `/calm` do Pi esconde elementos de transcript suportados - incluindo linhas de usuário operacionais do Squad classificadas canonicamente - e usa um indicador animado exclusivo do Calm durante execuções ativas, preservando todo o contexto do modelo e os dados da sessão. A preferência persiste para a base Squad efetiva, e desativá-la restaura a renderização comum. [O comportamento atual e os limites do Calm](docs/pt-BR/calm.md) são separados das suas [evidências com escopo de versão](docs/pt-BR/calm-mode-feasibility.md).

### Converse com ele

```sh
> olha meu projeto xyz no github, aí corrige o teste de login que falha às vezes e adiciona dark mode

# O Squad confere o toolchain (pedindo seu consentimento antes de instalar qualquer coisa),
# clona o projeto sob projects/ e despacha dois operadores isolados no backend ativo.
# Minutos depois:

  PR ready for review, commander: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> beleza, faz o merge
```

### Mais backends

Os guias de configuração do tmux (o padrão) e de todos os outros backends suportados (herdr, zellij, Orca, cmux) estão linkados em [Documentação](#documentação) abaixo.

## Funcionalidades

- **Um ponto de contato** - você fala somente com o agente da squad; ele despacha, supervisiona, escala apenas decisões reais e reporta resultados claros.
- **Uma squad visível** - cada operador trabalha na própria janela do tmux, aba experimental herdr/zellij, workspace cmux ou terminal Orca, que você pode assistir ou usar para digitar; o sargento de armas reconcilia.
- **Worktrees descartáveis** - cada tarefa roda em um worktree git limpo de um [FOB](https://github.com/runecraftai/squad/tree/main/packages/fob) (pool de worktrees), ou em um worktree gerenciado pelo Orca quando `backend=orca`, então trabalho paralelo em um mesmo repositório nunca colide.
- **Dois formatos de tarefa** - tarefas strike entregam mudanças autorizadas; tarefas recon deixam relatórios de investigação independentes quando o contrato de intake justifica pesquisa separada.
- **Modos de projeto explícitos** - cada projeto entrega via `drill`, `direct-PR` ou `local-only`, com a flag opcional de autonomia `+yolo`.
- **XOs opcionais** - XOs persistentes rodam a partir de bases Squad isoladas com seu próprio `SQUAD_BASE`, estado, projetos e lock de sessão, localmente ou como uma base inteira em um host SSH alcançável, com updates e recovery protegidos que nunca transformam uma rota remota indisponível em substituta local.
- **Supervisão orientada a eventos, zero tokens** - uma sentinela em bash acorda o sargento de armas apenas quando algo precisa de você; harnesses primários verificados também recebem um backstop de fim de turno que bloqueia ou dá seguimento a um stop às cegas quando há trabalho em andamento e a supervisão não está ativa.
- **Relay opcional** - ative com um token de pareamento local em `.env` para que o Squad possa responder suas menções públicas no X e no Discord, agir sobre pedidos normais reversíveis de menção pelo mesmo ciclo dos pedidos de chat, reconhecer trabalho despachado e postar até três follow-ups públicos seguros de conclusão dentro de sete dias - tudo sem alterar o comportamento fora do Relay. Uma resposta final prometida em uma thread vira estado durável reconciliado do disco, então um restart ou uma conversa compactada não pode perdê-la.
- **Fronteira rígida de projeto** - o sargento de armas é somente leitura sobre seus projetos, exceto pelas operações estreitas, protegidas e aprovadas pelo comandante autorizadas pela [regra dura 1](AGENTS.md#1-identity-and-prime-directives); operadores fazem toda outra mudança de projeto atrás da autoridade de merge configurada.
- **À prova de restart** - todo estado vive no disco e no backend de sessão ativo (tmux por padrão rígido); derrube a sessão quando quiser e a próxima reconcilia - incluindo agentes XO confirmados como mortos - e segue em frente.

## Skills embutidas

O Squad acompanha estas skills embutidas invocáveis pelo usuário. Claude e grok usam a forma com barra mostrada aqui; codex usa os mesmos nomes com `$`, como `$afk`.

| Skill          | O que faz                                                                                                                                                                                                                                                                              |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`         | Entra na supervisão em modo ausente: o sub-supervisor auto-trata notificações rotineiras em bash, escala eventos relevantes ao comandante e rechecks delimitados de espera externa declarada como digests em lote, e alerta ativamente se a entrega travar enquanto você se ausenta |
| `/reporting`   | Recapitula eventos visíveis da sessão desde a última mensagem real do comandante mais decisões do comandante visivelmente sem resposta, recaindo no Sitrep quando invocado como a primeira mensagem real do comandante na sessão                                                          |
| `/sitrep`      | Gera um digest conciso de quatro seções no chat a partir do estado local limitado da unidade e dos XOs registrados; use `/sitrep file` para também substituir o relatório datado de hoje em `data/`, e adicione `include PRs` quando quiser enriquecimento ao vivo de PRs                    |
| `/updatesquad` | Atualiza o Squad em execução e seus XOs para o mais recente da origem com pulls somente fast-forward, depois relê as instruções e cutuca os XOs                                                                                                                                                                                              |
| `/debrief`     | Varre a sessão em busca de conhecimento durável não capturado, encaminha cada achado ao seu dono durável conforme o AGENTS.md, arquiva próximos passos pendentes no backlog, propaga a mesma varredura para cada XO registrado contra o próprio orçamento de memória daquela base, e reporta o que agora é seguro resetar |

Exemplos de invocação do Sitrep:

- `/sitrep` retorna o digest fresco de quatro seções somente no chat.
- `/sitrep include PRs` mantém o modo somente-chat e opta pelo enriquecimento ao vivo de PRs.
- `/sitrep file` substitui do zero o `data/status-report-<YYYY-MM-DD>.md` de hoje e o linka a partir do digest de quatro seções no chat.
- `/sitrep file include PRs` combina o relatório datado com o enriquecimento ao vivo de PRs.

Skills de referência exclusivas de agentes vivem em `.agents/skills/` e são carregadas pelo Squad nos pontos de gatilho nomeados no [`AGENTS.md`](AGENTS.md).

### Layout de skills em duas camadas

As skills do Squad vivem em dois lugares separados, com públicos diferentes:

- `.agents/skills/` - skills carregadas pelo agente (a tabela acima, mais as skills de referência exclusivas de agentes). Cada uma pressupõe uma base Squad ativa e é inútil - ou ativamente enganosa - instalada em qualquer outro lugar, então cada uma carrega `metadata.internal: true` no frontmatter. Essa flag as esconde da descoberta de instaladores (ferramentas como o instalador `npx skills add` do [skills.sh](https://skills.sh)) sem afetar como o próprio Squad as carrega.
- `skills/` - skills públicas voltadas a instaladores, feitas para serem instaladas standalone em qualquer projeto, independentemente do Squad. Hoje é a `skills/debrief`, uma skill genérica de varredura de conhecimento de sessão que encaminha achados primeiro por instrução explícita, depois por convenções locais existentes, depois por um fallback privado em `.debrief-notes.md` no diretório atual. Ela deliberadamente não compartilha código com a `.agents/skills/debrief` interna do Squad que a inspirou no nome, para que as duas evoluam de forma independente.

## Pacotes

As ferramentas do Squad são distribuídas como pacotes standalone sob `packages/`, cada um com seu próprio README.

| Pacote     | O que faz                                                                                                                        | README                                       |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| drill      | Um proxy de git push que roda um pipeline de validação dirigido por IA em um worktree descartável e abre um PR limpo quando todas as verificações passam | [README](packages/drill/README.md)           |
| fob        | Gerencia um pool de worktrees git reutilizáveis e isolados para que cada agente ganhe um ambiente limpo instantaneamente                               | [README](packages/fob/README.md)             |
| pr-review  | Roda revisão de código paralela e escalonada de pull requests do GitHub com findings validados e um veredito de severidade                          | [README](packages/pr-review/README.md)       |
| sq-tasks   | Gerenciador de tarefas e backlog para agentes que edita um backlog markdown editável à mão in-place com custo quase nulo de tokens                  | [README](packages/sq-tasks/README.md)        |
| sq-gh      | Wrapper da GitHub CLI para agentes com saída eficiente em tokens, sugestões de próximo passo e erros estruturados                           | [README](packages/sq-gh/README.md)           |
| sq-browser | Automação de navegador ergonômica para agentes que envolve o chrome-devtools-mcp com uma CLI eficiente em tokens                              | [README](packages/sq-browser/README.md)      |
| sq-quota   | Reporta janelas de quota locais de Claude, Codex, Cursor, GitHub Copilot, Grok, Kimi e OpenCode em uma única chamada somente de dados                 | [README](packages/sq-quota/README.md)        |
| sq-report  | Abre HTML gerado por agentes em um editor local no navegador para você anotar elementos e mandar feedback ao agente                  | [README](packages/sq-report/README.md)       |
| sq-board   | Quadro de planejamento de missão que renderiza a fila do backlog com estado operacional ao vivo dos arquivos de estado duráveis do Squad                | [README](packages/operation-board/README.md) |

## Skills

O Squad descobre skills em várias superfícies:

- **Skills internas** (`.agents/skills/`) - procedimentos do Squad carregados sob demanda pelo harness do agente.
- **Skills públicas voltadas a instaladores** (`skills/`) - skills standalone para qualquer agente; symlinkadas de fontes fornecidas pelos pacotes durante o bootstrap.
- **Skills fornecidas por pacotes** (`packages/*/skills/`) - skills empacotadas junto aos pacotes, registradas automaticamente em `skills/` pelo `bin/sq-register-package-skills.sh`.

O script de registro é idempotente e roda durante o bootstrap. Ele descobre skills a partir de:

1. Diretórios convencionais `packages/*/skills/*/SKILL.md`
2. Pacotes com `"pi": {"skills": [...]}` no `package.json`

Para conferir quais skills seriam registradas sem modificar nada, rode:

```sh
bin/sq-register-package-skills.sh --check
```

Depois do bootstrap, verifique o link da skill pública com `test -e skills/sq-report/SKILL.md && echo sq-report-ready`.

### Descoberta por skills vs automação por hooks

Skills oferecem descoberta semântica/em prosa: o agente as carrega quando a tarefa bate com a descrição da skill. Hooks oferecem integração determinística de bootstrap: eles rodam no início da sessão para injetar contexto ambiente.

Os dois mecanismos são complementares:
- **Skills** tratam da descoberta de intenção em prosa ("crie um plano visual, comparação, diagrama, tabela, view de código ou relatório")
- **Hooks** tratam da integração no início da sessão ("sq-report está disponível, aqui estão as sessões ativas")

O pacote sq-report usa ambos: a skill pública para descoberta pelo agente e `setup hooks` para o contexto de início de sessão.

## Documentação

- [docs/architecture.md](docs/architecture.md) - arquitetura para mantenedores da squad, supervisão, worktrees, XOs e modos de projeto ([tradução pt-BR](docs/pt-BR/architecture.md)).
- [docs/configuration.md](docs/configuration.md) - variáveis de ambiente, `SQUAD_BASE`, seleção de backend de runtime, Relay opcional e seus passos de setup para X e Discord, os arquivos que você define e suporte a harness ([tradução pt-BR](docs/pt-BR/configuration.md)).
- [docs/remote-XOs.md](docs/remote-XOs.md) - setup, roteamento, transferência, recovery e segurança atuais para XOs remotos de base inteira ([tradução pt-BR](docs/pt-BR/remote-XOs.md)).
- [docs/calm.md](docs/calm.md) - comportamento atual do `/calm` do Pi e limites de apresentação suportados ([tradução pt-BR](docs/pt-BR/calm.md)).
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure o alerta ativo para uma entrega de escalação do modo ausente que travar ([tradução pt-BR](docs/pt-BR/wedge-alarm.md)).
- [docs/tmux-backend.md](docs/tmux-backend.md) - setup e limites atuais do backend de referência tmux ([tradução pt-BR](docs/pt-BR/tmux-backend.md)).
- [docs/status-notify.md](docs/status-notify.md) - notificações de desktop para eventos de acordar done/blocked dos operadores, com ação de foco no tmux ([tradução pt-BR](docs/pt-BR/status-notify.md)).
- [docs/sq-sidebar.md](docs/sq-sidebar.md) - a sidebar tmux do Squad (workmux vendado): cards de status por janela a partir dos arquivos de estado ground-truth, em um painel alternável ([tradução pt-BR](docs/pt-BR/sq-sidebar.md)).
- [docs/web-view.md](docs/web-view.md) - dashboard web somente leitura do estado dos operadores, servido na LAN para visualização de outra máquina ou celular ([tradução pt-BR](docs/pt-BR/web-view.md)).
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup, fronteiras de segurança e limites atuais do backend experimental Herdr ([tradução pt-BR](docs/pt-BR/herdr-backend.md)).
- [docs/zellij-backend.md](docs/zellij-backend.md) - setup e limites atuais do backend experimental Zellij ([tradução pt-BR](docs/pt-BR/zellij-backend.md)).
- [docs/orca-backend.md](docs/orca-backend.md) - setup e limites atuais do backend experimental Orca ([tradução pt-BR](docs/pt-BR/orca-backend.md)).
- [docs/cmux-backend.md](docs/cmux-backend.md) - setup, segurança de socket e limites atuais do backend experimental cmux ([tradução pt-BR](docs/pt-BR/cmux-backend.md)).
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - a fronteira atual bloqueada do backend Codex App e o contrato de rollout ([tradução pt-BR](docs/pt-BR/codex-app-backend.md)).
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - verificação ativa para mantenedores das garantias dos backends de runtime.
- [docs/gitlab-merge-sentry.md](docs/gitlab-merge-sentry.md) - verificação para mantenedores do monitoramento de merge GitLab em instâncias arbitrárias ([tradução pt-BR](docs/pt-BR/gitlab-merge-sentry.md)).
- [docs/turnend-guard.md](docs/turnend-guard.md) - o backstop "nenhum turno termina às cegas" atual da sessão primária, escopo, segurança de loop e limites de compatibilidade ([tradução pt-BR](docs/pt-BR/turnend-guard.md)).
- [docs/verification/supervision.md](docs/verification/supervision.md) - verificação ativa para mantenedores das integrações de início de sessão, guard, continuity e wedge.
- [docs/supervision-protocols/](docs/supervision-protocols/) - protocolos de sentinela renderizados por harness primário para Claude, Codex, OpenCode, Pi e `pi-signed`, Grok e fallback para harness desconhecido ([traduções pt-BR](docs/pt-BR/supervision-protocols/)).
- [docs/scripts.md](docs/scripts.md) - a referência das ferramentas de `bin/` ([tradução pt-BR](docs/pt-BR/scripts.md)).
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - públicos da documentação e a fronteira de posicionamento verificada por máquina ([tradução pt-BR](docs/pt-BR/documentation-audiences.md)).
- [`AGENTS.md`](AGENTS.md) - o contrato operacional sempre carregado da distro e o índice de roteamento para procedimentos condicionais.
- [CONTRIBUTING.md](CONTRIBUTING.md) - como contribuir, incluindo os comandos de dev/teste.

## Contribuir

Contribuições são bem-vindas - veja [CONTRIBUTING.md](CONTRIBUTING.md) para o fluxo de trabalho, as convenções do repositório e como rodar os testes.

## Licença

MIT - veja [LICENSE](LICENSE).
