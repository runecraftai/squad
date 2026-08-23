<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Second mates remotos

Second mates remotos colocam uma base Squad inteira e persistente em outro host alcançável por SSH.
O primário ainda controla roteamento e supervisão, enquanto a base remota controla seus próprios projetos, backlog e workers.
O Squad não suporta colocar um worker individual remotamente ou falhar uma rota remota para um substituto local.

O agente second-mate remoto em si sempre roda no [backend Herdr](../herdr-backend.md) na sessão compartilhada `sq-remote`, e todo caminho que provisiona ou lança um recusa um host que não está pronto para ele.
`sq-remote` é reservado para trabalho remoto de unidade e não deve ser usado para trabalho pessoal.
A sessão Herdr interativa do usuário permanece `default` e não é pré-requisito de remote-XO.
O servidor de sessão remota do Herdr pertence à sessão de login GUI do próprio host em vez da conexão SSH, então o endpoint do agente sobrevive a toda desconexão da qual a supervisão do primário depende.
Second mates locais não são afetados e mantêm seu backend e seleção de sessão ordinários, assim como os workers que um second-mate remoto supervisiona dentro de sua própria base.

## Pré-requisitos

Configure um alias SSH na configuração OpenSSH normal da conta primária.
Use autenticação por chave pública ordinária, verificação estrita de host-key e uma conta remota dedicada quando viável.
Não habilite forwarding de agentes para o Squad.
`sq-on.sh` também desabilita forwarding de agentes, configuração de forwarding e padrões configurados `SendEnv` em toda chamada, e arma detecção limitada de dead-peer SSH para que um host desaparecido (reboot, link perdido) falhe dentro de uma janela limitada em vez de travar indefinidamente; seu [cabeçalho de script](../../bin/sq-on.sh) é dono dos defaults de keepalive e overrides de ambiente.

Clone o Squad no host remoto num caminho absoluto de raiz de código.
Exponha o entrypoint fixo desse clone no `PATH` SSH não-interativo da conta, por exemplo:

```sh
mkdir -p ~/.local/bin
ln -s /caminho/absoluto/para/Squad/bin/sq-remote-entrypoint.sh ~/.local/bin/sq-remote-entrypoint.sh
```

O entrypoint aceita argv codificado apenas para arquivos `bin/sq-*.sh` executáveis genuínos.
Ele nunca aceita string de comando shell.
O doctor que controla prontidão roda sobre este bootstrap SSH simples para que o modo read-only possa reportar gaps de workers e `--fix` possa instalar ou reparar o worker.
O entrypoint autoriza aquele bootstrap com tracking git normal quando git resolve e com seu digest fixo de doctor quando o doctor precisa reportar que o próprio git está faltando.
Depois do setup, todo outro comando verifica o remote job worker de propriedade da conta do Squad, prepara o argv codificado e bytes stdin, espera pelo resultado, e transmite stdout, stderr e status de saída separadamente.
No macOS o worker é `dev.Squad.remote-job`, um LaunchAgent com escopo Aqua em `~/Library/LaunchAgents/dev.Squad.remote-job.plist` com logs sob `~/Library/Logs/`.
Depois daquele bootstrap todo `sq-on.sh` alvo não-doctor roda através daquele worker na sessão GUI da conta remota, nunca no processo SSH ou num pane Herdr.
O worker roda um job preparado por vez e preempta um reply long-poll rodando assim que qualquer comando diferente de outro reply long-poll é enfileirado, então comandos interativos e checagens de startup nunca são serializados atrás de uma janela de polling.
`bin/sq-remote-job-lib.sh` é dono desse contrato de preempção, e um poll preemptado é indistinguível de um cuja janela de espera fechou sem dados, então o rearmed poll não perde nada.
Linux usa a mesma fila e protocolo de worker sem o requisito de sessão Aqua.
Um worker para uma vez que sua raiz de código configurada deixa de ser um checkout do Squad, então um worker iniciado de um worktree não pode sobreviver àquele worktree, e `bin/sq-remote-job-reap-orphans.sh` limpa qualquer worker já deixado dessa forma sem nunca tocar um cujo checkout ainda existe.
A conta remota deve fornecer a toolchain exigida, o runtime do worker selecionado, o backend de sessão selecionado, e credenciais que funcionem naquele host.
A URL de origem nomeada para cada projeto deve ser alcançável da conta remota porque projetos são clonados naquele host em vez de copiados do primário.

## Contrato de ferramenta não-interativo

Nenhum shell interativo ou de login roda no host remoto, então `~/.profile`, `~/.bashrc` e `~/.zshrc` nunca contribuem para o `PATH` de runtime.
`bin/sq-remote-job-lib.sh` é o único dono do `PATH` do worker e o constrói por descoberta de filesystem em vez de avaliar arquivos de startup de shell.
O filho autorizado vê `<remote-root>/bin` primeiro, depois um `~/.local/bin` genuíno da conta, a versão default bin do nvm, shims e install bins do asdf, shims e install bins do mise, diretórios Nix, diretórios Homebrew, e o tail do sistema `/usr/bin:/bin:/usr/sbin:/sbin`.
Seleção nvm segue a chain `alias/default` do filesystem e escolhe a versão semântica installada correspondente mais alta, recuando para a versão semântica installada mais alta quando o alias está ausente ou não tem match instalado.
Um default `system` do nvm não adiciona nenhuma versão bin do nvm, então os diretórios posteriores do sistema fornecem Node.
A ordem de Nix e package-manager após descoberta do version-manager é `~/.nix-profile/bin`, `/etc/profiles/per-user/<conta>/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin` e `/usr/local/bin`.
Entradas exatas repetidas são omitidas.
Para os três locais Nix, um symlink final `bin` é resolvido para seu diretório físico, enquanto um caminho alcançado através de ancestrais symlinked permanece em sua posição documentada.
Outros diretórios de componente final symlinked, incluindo `~/.local/bin`, são excluídos.
O entrypoint resolve `git` apenas da porção do operador antes de prependar `<remote-root>/bin` para o filho autorizado.
Um `bin/git` local-ao-checkout portanto não pode autorizar um comando não rastreado, e um host sem `git` do operador recebe um diagnóstico de install-or-wrapper antes da execução do comando.

A descoberta de filesystem normalmente encontra ferramentas instaladas por nvm, asdf ou mise sem iniciar seus hooks de shell.
Quando uma ferramenta necessária continua descoberta apenas através de um desses gerenciadores, `sq-remote-doctor.sh --fix` pode criar um wrapper de propriedade do Squad em `~/.local/bin` que executa seu alvo absoluto selecionado.
Ele nunca sobrescreve um wrapper ou outro arquivo do qual não é dono, e nunca instala um pacote.
Um operador pode usar o mesmo formato de wrapper quando uma ferramenta precisa de seleção manual.
O wrapper abaixo fornece o alias de protocolo backlog-backend que o runtime remoto
invoca (contrato: `bin/sq-tasks-lib.sh`); sua linha `exec` deve apontar para o
binário instalado `sq-tasks`, nunca para outro wrapper:

```sh
mkdir -p ~/.local/bin
cat > ~/.local/bin/tasks-axi <<'SH'
#!/usr/bin/env bash
tool_bin="$HOME/.nvm/versions/node/<versao-selecionada>/bin"
PATH="$tool_bin:$PATH"
exec "$tool_bin/sq-tasks" "$@"
SH
chmod +x ~/.local/bin/tasks-axi
```

Substitua o placeholder pela versão nvm selecionada da conta remota.
Para asdf ou mise, use o mesmo formato com o diretório `bin` absoluto da versão selecionada, um wrapper por ferramenta que a base remota realmente precisa.
O wrapper deve executar aquele alvo absoluto em vez de resolver o próprio nome novamente através de `~/.local/bin`.

## Prontidão, reparo e passos humanos

`bin/sq-remote-doctor.sh` é o único dono do significado de "pronto para um second mate remoto".
Confira qualquer host contra ele diretamente:

```sh
bin/sq-on.sh <id-XO|alias-ssh> sq-remote-doctor.sh
```

Essa execução é read-only.
Ela imprime o `PATH` exato que o lançamento do próprio entrypoint produziu, executa sua sonda de ferramentas necessárias através do worker instalado quando um está disponível, reporta onde cada ferramenta necessária e opcional resolveu, depois reporta uma linha por checagem de prontidão.
Cada gap é marcado `fixable:` quando `--fix` pode fechá-lo ou `human:` quando apenas uma pessoa naquela máquina pode, e cada gap é seguido por uma linha `action:` nomeando o passo exato.
Qualquer gap restante sai com código diferente de zero.
O cabeçalho do próprio script é dono do protocolo completo de linhas.

`--fix` repara apenas os gaps automatizáveis e é seguro para re-executar:

```sh
bin/sq-on.sh <id-XO|alias-ssh> sq-remote-doctor.sh --fix
```

Sobre o bootstrap simples do doctor SSH, ele escreve e recarrega os launch agents de propriedade do Squad `dev.Squad.remote-job` e `dev.Squad.herdr.sq-remote` no macOS, ambos com escopo `LimitLoadToSessionType=Aqua` e bootstraped em `gui/<uid>`.
Ele inicia os mesmos workers diretamente no Linux, recria o symlink `~/.local/bin/sq-remote-entrypoint.sh` quando ausente, e cria apenas wrappers de ferramentas necessárias de propriedade do Squad que consegue provar que resolvem para um alvo de version-manager, parando depois que um harness satisfaz o requisito de-pelo-menos-um.
Ele nunca instala pacotes nem sobrescreve um arquivo não-Squad num caminho reservado de wrapper.
O launch agent Herdr dedicado é dono apenas do servidor `sq-remote` de remote-XO e não inspeciona, reescreve, inicia, para, ou requer a sessão interativa `default` do usuário ou seu launch agent `dev.Squad.herdr`.
Ele re-deriva toda checagem do host depois, então o que ele imprime é o estado após o reparo em vez da intenção de uma vez.

Estes passos nunca são automatizados e sempre são reportados em vez de tentados silenciosamente, porque SSH não consegue criar uma sessão GUI do nada:

- O primeiro login de console naquele Mac, e login automático em System Settings > Users & Groups quando a máquina roda headless e precisa voltar sozinha após um reboot.
- FileVault, que segura um reboot em autenticação pré-boot antes que qualquer sessão de login exista.
- Instalar qualquer ferramenta necessária ausente que nenhum wrapper seguro consiga resolver.
- O conjunto remoto exigido de ferramentas é `git`, `jq`, `herdr`, `sq-tasks` compatível (instalado com seu alias de protocolo backlog-backend, conforme `bin/sq-tasks-lib.sh`), `fob`, e pelo menos um de `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok` ou `kimi`.
- O `/login` de cada runtime de worker, e qualquer prompt de senha de keychain que o login necessite.

O Squad nunca escreve senha de auto-login, nunca muda FileVault, e nunca armazena senha de conta.
Um arquivo em `~/.local/bin/sq-remote-entrypoint.sh` que não é o próprio symlink do Squad é reportado para o operador inspecionar e nunca é sobrescreto.

## Provisionar uma rota

Crie e preencha o charter normal do XO primeiro, depois rode:

```sh
bin/sq-remote-home-seed.sh <id> <alias-ssh> <remote-root> <remote-home> {<projeto>[=<url-de-origem>]...|--no-projects}
```

`<remote-root>` é o clone do código Squad remoto que fornece os scripts rastreados.
`<remote-home>` é um caminho absoluto separado para a base XO persistente e não deve sobrepor a raiz de código.

Nomeie a origem de cada projeto como `<projeto>=<url-de-origem>`.
Resolva a origem concreta do comandante, do registro de projetos, de um clone existente em qualquer lugar, do forge, ou de uma colagem explícita em vez de impor um template de URL.
Semear um projeto que esta máquina nunca clonou não precisa de clone sob `projects/`, de inicialização `drill` aqui, nem de unit sync antes.
Um `<projeto>` puro ainda é aceito quando esta máquina tem `projects/<projeto>`, cuja origem configurada é lida em vez de ser redigitada.
[`bin/sq-project-origin-lib.sh`](../../bin/sq-project-origin-lib.sh) é dono de quais URLs são aceitas; ele decide apenas por estrutura e segurança, então nenhum forge, domínio ou host tem privilégio e um servidor self-hosted funciona exatamente como um hospedado.
O primário valida toda origem resolvida antes do transporte, e o host receptor a valida novamente antes de clonar.
O modo de entrega registrado do projeto ainda vem do `data/projects.md` desta máquina, então um projeto não registrado ou `local-only` é recusado em vez de provisionado.

O seed registra `host:`, `root:` e `home:` em `data/XOs.md`, condiciona o host à prontidão, envia um manifesto limitado, e deixa o host remoto clonar sua própria base Squad e origens de projetos.
Na base primária, seus efeitos de registro durável são limitados àquela rota e ao brief do charter sob `data/<id>`; registros de lançamento são criados apenas quando o XO é lançado.
Prontidão começa com checagem read-only; quando aquela checagem reporta um gap, ela roda `--fix` e depois uma segunda checagem read-only cujo veredito decide, então o operador nunca precisa rodar o reparo à mão e um reparo nunca é confiado pela própria palavra.
Um host que continua vermelho imprime os gaps restantes do doctor e seus passos de operador, restaura o registro, e não cria nada no host remoto.
Ele não copia árvores de projeto nem o ambiente do processo primário.
Uma falha de provisionamento conhecida faz rollback da nova rota, enquanto SSH exit 255 preserva-a porque a conclusão remota é desconhecida e deve ser reconciliada no mesmo host.

Seed também escreve um registro durável `.sq-xo-parent` ao lado do marcador de identidade `.sq-xo-home` da base, nomeando a rota desta base para seu pai como `local` ou `remote`.
O subsistema de resposta-pública-prometida é same-system-por-construção, então uma rota remota nunca pode carregar uma promessa delegada de resposta pública; o gate de cleanup de `bin/sq-teardown.sh` lê este registro para tratar um pai remoto como fora do escopo em vez de binding não resolvido.

XOs locais mantêm o formato de rota existente e não precisam de migração.
Uma unidade pode conter rotas locais e remotas juntas.
Use `bin/sq-home-seed.sh validate` para validar qualquer forma.

## Operação normal

Lance ou recupere o second mate remoto com o mesmo comando usado para uma rota local:

```sh
bin/sq-spawn.sh <id> --xo
```

O primário resolve o harness XO verificado e modelo e esforço opcionais, roda o mesmo gate de prontidão que o seed roda, transmite a allowlist de material herdado, e pede ao host remoto para lançar no Herdr em `sq-remote`.
Todos os XOs remotos num host compartilham `sq-remote` e retêm workspaces separados `xo-<id>` dentro dele.
Um pedido explícito para qualquer outro backend é recusado em vez de honrado, e o host remoto também recusa um.
Um endpoint remoto existente registrado em outra sessão Herdr, incluindo `default`, é classificado como não verificado e deixado intocado; launch, recovery de vitalidade, controle e aposentadoria recusam-no até que um operador explicitamente o migre em vez de tentar um cutover ao vivo.
Um launch depois que um host divergiu da prontidão falha com o próprio texto de gaps do doctor em vez de deixar um endpoint meio-criado.
Comandos de launch brutos não são aceitos para XOs remotos.
Backends que já recusam launch de XO, atualmente Orca e cmux, permanecem não suportados no host remoto.

Recovery de vitalidade no startup relança um second mate remoto morto ou ausente através deste mesmo comando, então recovery passa pelo mesmo gate de prontidão em vez de um mais fraco.

Envie pedidos roteados normalmente:

```sh
SQUAD_BASE=<primary-home> bin/sq-send.sh sq-<id> '<pedido>'
```

Pedidos marcados mantêm o contrato de correlação existente.
O charter remoto appenda replies em `state/parent-replies.status` na base remota.
Uma fonte process-event faz uma leitura delta não-destrutiva e ancora-na-cursor, busca apenas documentos `data/*.md` referenciados através do reader confinado, espelha cada linha portadora de conteúdo no máximo uma vez no canal de status primário, e não carrega separadores em branco.
O canal carrega o status e modelo de decisão do mate: uma linha de progresso não-correlacionada e um `needs-decision` recém-levantado viajam o mesmo caminho que uma resposta correlacionada, e alcançam o fold de open-decision do pai idênticamente.
Correlação é uma propriedade por linha que settle um pedido pendente; nunca é gate no stream, então nenhuma linha individual pode parar ou travar o relay ou segurar o cursor.
Normalização de transporte reescreve NUL, todo outro C0 exceto tab e newline, e DEL para `?`, enquanto ASCII imprimível e todos os bytes altos, incluindo UTF-8, passam inalterados.
Se o reader remoto confinado recusa permanentemente um documento referenciado, a linha do mate é espelhada com seu ponteiro original e o adaptador appenda uma escalação chaveada nomeando o gap em vez de travar o stream.
Um SSH exit status 255 durante busca de documento referenciado deixa o delta não commitado para o retry normal do runner de process-event porque a conclusão remota é desconhecida.
O runner de process-event aplica cada delta capturado através deste adaptador assim que capturado, então uma reply espelhada alcança o canal de status primário sem depender do wake handler rodar o próprio adaptador.
Uma linha espelhada que carrega token de correlação settle seu registro de pending-reply e fecha a open escalation decision daquele pedido, enquanto uma aplicação que não completa deixa o capture sem acknowledge para o caminho de retry documentado do handler.
O [contrato operacional de process-to-event](../configuration.md#process-to-event-sources-stateprocevent) é dono daquela aplicação automática e de seu limite de retry.
O log da fonte nunca é truncado ou consumido.
Um prefixo encurtado ou alterado para o relay e surface uma falha de continuidade em vez de resetar silenciosamente o cursor.

Um SSH exit status 255 sempre significa falha de transporte ou conclusão remota desconhecida.
O transporte nunca retenta automaticamente.
Chamadores semânticos preservam a rota ou pedido pendente e exigem reconciliação no mesmo host em vez de reenviar uma operação que pode já ter acontecido.
Uma base remota indisponível é projetada como unknown e nunca é substituída por um second mate local.

## Handoff de backlog

Movimento de trabalho enfileirado já julgado com o comando normal:

```sh
bin/sq-backlog-handoff.sh <id> <item-key>...
```

Para uma rota remota, `sq-teams mv` primeiro move o conjunto com dependências fechadas atomicamente do backlog primário para `data/handoff/<id>.outbox.md`.
O outbox é então copiado para o diretório scratch de handoff remoto e `sq-backlog-receive.sh` ingere atomicamente toda chave ausente no destino sob o próprio lock do backlog remoto.
Receita confirmada remove o outbox.
Um outbox existente é o registro completo de retry, e `--resume-pending` o re-entrega com segurança.
Bootstrap retenta outbox pendentes e emite `XO_HANDOFF:` apenas quando um permanece.
Não há journal de duas fases nem requisito adicional de release do sq-tasks.

## Sync, update e aposentadoria

Convergência de startup travada e `bin/sq-config-push.sh` transferem apenas a allowlist declarada de material herdado.
Rotas vivas alteradas recebem uma instrução marcada para reler os arquivos transferidos.
O primário registra aquele nudge remoto antes da entrega e o retenta durante convergência de startup travada após envio falho.
XOs locais retêm seu contrato de ponteiro local específico de geração; transferências remotas não copiam aqueles caminhos de instrução local-ao-primário.

`/updatesquad` atualiza cada raiz de código remota de sua própria origem, depois guardedly fast-forwards a base remota persistente para aquele commit da raiz de código.
Alvos sujos, divergentes, indisponíveis ou de outra forma inseguros são reportados e deixados intactos.

Aposente um second mate remoto com o comando normal protegido:

```sh
bin/sq-teardown.sh <id>
```

Aposentadoria é executada no host configurado e recusa enquanto a base remota tem trabalho filho, enquanto o primária tem um outbox de backlog não terminado, ou enquanto uma reply roteada permanece não resolvida.
Ela fecha apenas os panes ou workspace `xo-<id>` em `sq-remote` do XO sendo aposentado; nunca para a sessão compartilhada nem remove workspace ou panes de um XO irmão.
SSH exit 255 preserva tanto a rota quanto os registros locais porque conclusão é desconhecida.
`--force` permanece o caminho explícito de descarte e requer a mesma autoridade do comandante que descarte de XO local.
Nenhuma superfície genérica de delete ou escrita remota existe: escritas remotas são confinadas a arquivos da allowlist herdada e arquivos scratch de handoff de backlog, e remoção de base remota é alcançável apenas através de aposentadoria protegida de XO.

## Verificação

Os testes portáteis usam o protocolo real de entrypoint, repositórios git reais, uma fronteira SSH determinística, um fixture stateful local-à-máquina do CLI Herdr, e um fixture controlado de conta para o gate de prontidão.
O teste de ciclo de vida cobre seeding de um projeto registrado que esta máquina nunca clonou, afirma que a árvore local do projeto está inalterada depois, e carrega origens do tipo Bitbucket, self-hosted e scp até o clone remoto:

```sh
bin/sq-test-run.sh tests/sq-on.test.sh
bin/sq-test-run.sh tests/sq-remote-job.test.sh
bin/sq-test-run.sh tests/sq-remote-doctor.test.sh
bin/sq-test-run.sh tests/sq-project-origin.test.sh
bin/sq-test-run.sh tests/sq-remote-reply.test.sh
bin/sq-test-run.sh tests/sq-remote-backlog-handoff.test.sh
bin/sq-test-run.sh tests/sq-remote-XO-lifecycle-e2e.test.sh
bin/sq-test-run.sh tests/sq-remote-XO-trace-context.test.sh
```

As checagens de nível de conta que o doctor executa - uma sessão real de login Aqua, um domínio real `launchctl`, e um servidor real herdr - são apenas exercitadas contra fixtures aqui, então o comportamento do gate de prontidão num Mac genuíno continua sendo um smoke test executado pelo operador.

Para um smoke test em host real, provisione uma conta e projeto remoto descartáveis, rode o doctor e seu reparo contra aquela conta, lance o second mate, envie um pedido marcado, verifique sua reply correlacionada e projeção unitária estruturada, simule um host inalcançável para confirmar comportamento unknown-sem-failover, depois aposente apenas depois que a fila remota estiver vazia.
A suíte determinística é automatizada; validação em host real continua sendo um smoke test executado pelo operador e não é reivindicado pelos testes do repositório.
