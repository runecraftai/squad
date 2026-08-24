<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Verificação de monitoramento de merge requests GitLab

Registro empírico do monitoramento de merge no GitLab, ao lado do watch GitHub existente.
Todo comando abaixo foi rodado em 2026-07-21 e sua saída é reproduzida exatamente.

## Versões

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## O projeto de evidência

Toda evidência ao vivo aqui lê <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, um projeto público que existe apenas para ser esta evidência.
Ele contém um merge request deliberadamente mesclado e um deliberadamente aberto, para que ambos os resultados possam ser mostrados contra dados reais.
Todo comando contra ele lê um merge request público e não precisa de credencial, então um leitor pode reexecutar cada um e ver a mesma saída.
O README dele pede que o merge request aberto seja deixado aberto.

Um host não padrão aparece abaixo apenas como o placeholder `gitlab.example`, que não resolve em lugar nenhum.
Isso é deliberado: a propriedade agnóstica-a-host é uma propriedade do registro armazenado e da reconstrução de URL do poll, então é demonstrada inspecionando esses em vez de alcançar qualquer instância privada.

## Por que o host é dado e não constante

O GitLab roda majoritariamente em instâncias self-hosted, então um merge request pode viver sob qualquer host.
Um projeto GitLab também fica sob pelo menos um group sem profundidade fixa, então nenhum par dono-e-repositório consegue endereçá-lo como no GitHub.
O registro armazenado portanto carrega `provider`, `url`, `host`, `path` e `number`, e todo consumidor reconstrói a URL dessas partes e recusa qualquer registro que não reconstrua exatamente a URL armazenada.
`tests/sq-pr-check-security.test.sh` afirma que nem `bin/sq-pr-lib.sh` nem `bin/sq-pr-poll.sh` contêm a string `gitlab.com`.

## Como o glab puro é invocado, e por quê

Duas coisas sobre o `glab` puro foram estabelecidas executando-o, porque assumir qualquer uma delas teria falhado silenciosamente num permanente "não mesclado".

Primeiro, o `glab` puro não tem seletor de campo.
O `gh` lê um campo com `--json state -q .state`; o `glab mr view` oferece apenas `-F, --output string  Format output as: text, json`.
Seu JSON precisaria de um processador JSON, e `jq` não está entre as ferramentas comuns do Squad, então o estado é lido da saída de campos do próprio glab.
Apenas um `merged` exato acorda o Squad, então um formato de saída alterado não produz acordo em vez de falso merge.

Segundo, o `glab` não aceita uma URL de merge request como o `gh pr view` aceita.
Essa forma delega ao git para o repositório atual, e a sentinela roda fora de qualquer repositório:

```
$ cd /tmp && glab mr view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
fatal: not a git repository (or any parent up to mount point /)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
git: exit status 128
```

Passar a URL do projeto para `-R` com o número do merge request funciona de qualquer lugar, e resolve a instância a partir daquela URL em vez do default configurado do glab:

```
$ cd /tmp && glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
title:	Add the merged example file
state:	merged
author:	KarotKris
labels:	
assignees:	
reviewers:	
comments:	0
number:	1
url:	https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
--
This merge request is the merged half of the fixture. It is merged on purpose, so that reading its state returns merged.

$ cd /tmp && glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture | sed -n 's/^state:[[:space:]]*//p'
open
```

## Fim a fim: armando e fazendo polling de um merge request real

Três tarefas foram armadas, duas contra o fixture e uma contra o host placeholder:

```
$ sq-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ sq-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ sq-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

O registro armazenado de cada, mostrando o host e o namespace completo do projeto como dados:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

O registro de proveniência do host não padrão, mostrando a tag de versão incrementada:

```
$ cat state/e3.pr-poll-registration
sq-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

Executando cada poll publicado do jeito que a sentinela faz, onde resultado vazio significa que o poll ficou silencioso e não produziu acordo:

```
$ sq-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ sq-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ sq-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

O merge request fixture mesclado produz exatamente uma linha `merged`.
O aberto não produz nada, e o host placeholder inalcançável não produz nada em vez de falso merge.

Os mesmos bytes funcionam no modo sidecar-driven da sentinela, onde a checagem publicada localiza seu próprio registro:

```
$ state/e1x.check.sh
merged
```

## Uma CLI ausente não produz acordo, nunca falso merge

O poll fica silencioso em todo erro por design, então um `glab` ausente seria indistinguível de um merge request nunca mesclado.
Com `glab` removido do `PATH`, o poll continua silencioso mesmo para o merge request genuinamente mesclado:

```
$ PATH="$noglab" sq-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" sq-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```
Armar é o único ponto onde isso pode ser reportado, então ele recusa ali em vez de armar um watch que nunca pode disparar:

```
$ PATH="$noglab" sq-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

Uma tarefa GitHub não é afetada por `glab` ausente:

```
$ PATH="$noglab" sq-pr-check.sh e6 https://github.com/runecraftai/squad/pull/750  # placeholder OQ-03
armed: state/e6.check.sh
```

## Caminho de upgrade a partir de um watch já armado

O registro armazenado ganhou a tag provider, então sua versão moveu-se para `sq-pr-poll-registration-v2` e um registro escrito pela release anterior não parseia mais.
A migração existente não-executante cuida disso: ela nunca executa o artefato antigo, e reconstrói o poll a partir da URL de pull request registrada da tarefa.
Partindo de um poll armado exatamente como a release anterior o escreveu:

```
$ head -1 state/t1.pr-poll-registration
sq-pr-poll-registration-v1
$ sq-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this base
$ head -2 state/t1.pr-poll-registration
sq-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

O poll reconstruído funciona, verificado contra um pull request genuinamente mesclado:

```
$ sq-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

Nenhum watch armado é perdido no upgrade.

## O que esta mudança não cobre

`bin/sq-pr-merge.sh` ainda endereça apenas GitHub, por dono e repositório.
Ele recusa uma URL de merge request GitLab em vez de enviá-la ao forge errado, então mesclar um merge request continua passo manual deliberado até a paridade de merge chegar separadamente.

Uma tarefa GitLab registra nenhum `pr_head=`.
O `gh` expõe o commit head como campo selecionável, enquanto o `glab` puro o expõe apenas dentro da saída JSON dele, que exigiria um processador JSON que o Squad não exige.
Ambos os consumidores já o tratam como opcional: `bin/sq-teardown.sh` lê o head do forge no teardown em vez dos metadados e recua para sua checagem de conteúdo agnóstica-a-provider, e `bin/sq-review-diff.sh` resolve o head do remoto quando nenhum está registrado.
