<h1 align="center"><code>git push drill</code></h1>
<p align="center">
  <a href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-blue?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Acabe com todo o slop. Abra um PR limpo.</h3>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <strong>Português (Brasil)</strong></p>

O `drill` coloca um proxy git local na frente do seu remote real.
Em vez de `origin`, faça push para `drill`: ele cria um worktree descartável, executa um pipeline de validação dirigido por IA, encaminha a branch para o destino de push configurado somente depois que todas as verificações passam e abre um PR limpo automaticamente.

- **Não bloqueante** - o pipeline roda em um worktree isolado sem interromper o seu trabalho.
- **Independente de agente** - `claude`, `codex`, `rovodev`, `opencode`, `pi`, `copilot` ou `cursor` / `acp:<target>` via `acpx`, com fallbacks em ordem; todo gate exige um agente de pipeline configurado e executável.
- **Nativo para agentes** - o `/drill` permite que o seu agente de código execute uma tarefa e a envie ao gate, ou envie ao gate trabalho já commitado: ele roda o pipeline, faz o pipeline aplicar correções seguras e encaminha o restante para você.
- **O humano continua no controle** - auto-fix ou revisão das findings, a decisão é sua.
- **PRs limpos por padrão** - push, abertura de PR, acompanhamento do CI e auto-fix de falhas de uma só vez.

Documentação completa: <https://github.com/runecraftai/squad/tree/main/packages/drill/docs>

## Como funciona

```
        sua branch
            │  git push drill
            ▼
   ┌──────────────────────────────────────────────────────┐
   │  worktree descartável ─ seu trabalho fica onde está  │
   │  review → test → docs → lint → push → PR → CI        │
   └──────────────────────────────────────────────────────┘
            │  cada verificação verde
            ▼
        PR limpo, aberto para você
```

Cada etapa ou passa sozinha, ou para com uma **finding** para você agir.
Correções seguras e mecânicas são aplicadas automaticamente; qualquer coisa que toque a sua **intenção** é encaminhada para você **approve (aprovar)**, **fix (corrigir)** ou **skip (pular)**.
Nada chega ao destino de push configurado até que cada verificação esteja verde.

## Instalação

```sh
curl -fsSL https://raw.githubusercontent.com/runecraftai/squad/main/packages/drill/docs/install.sh | sh
```

As instruções para Windows, Go install e build a partir do código-fonte estão no [guia de instalação](https://github.com/runecraftai/squad/tree/main/packages/drill/docs/src/content/docs/start-here/installation.md).

## Início rápido

```sh
$ drill init
  ✓ Gate initialized

    repo  /Users/you/src/my-repo
    gate  drill → /Users/you/.drill/repos/abc123def456.git
  remote  git@github.com:you/my-repo.git
   skill  /drill installed for agents at user level

  Push through the gate with:
  git push drill <branch>

$ git checkout my-branch

# faça algum trabalho na branch...

$ git push drill
  * Pipeline started

  Run drill to review.

$ drill
# abre a TUI da execução ativa
```

Para contribuições via fork no GitHub, mantenha o `origin` apontando para o repositório pai e inicialize com `drill init --fork-url <your-fork-url>`.

Pela TUI você trata cada **finding**: as do tipo **auto-fix** são aplicadas para você (ou você approve para liberá-las), e as do tipo **ask-user** exigem o seu julgamento: você approve, fix ou skip.
Quando cada verificação fica verde, o gate encaminha a sua branch para o destino de push configurado e abre o PR para você: sem `git push origin` manual e sem corpo de PR escrito à mão.
Prefere deixar o seu agente de código conduzir o mesmo fluxo sem supervisão?
Use o `/drill` (veja abaixo).

## Três formas de acionar o gate

Toda alteração passa pelo mesmo pipeline.
Escolha o ponto de entrada que se encaixa no seu jeito de trabalhar quando a alteração estiver pronta:

- **`git push drill`** - o caminho Git explícito. Empurre uma branch commitada para o remote do gate em vez do `origin`.
- **`drill`** - a TUI. Rode após fazer alterações (sem precisar commitar) e um assistente guia você na criação da branch, no commit e no push pelo gate, e então anexa você à execução. O `drill -y` faz tudo isso automaticamente.
- **`/drill`** - a skill de agente. Diga ao agente de código para executar uma tarefa e enviá-la ao gate com `/drill <task>`, ou use `/drill` sem argumentos para enviar ao gate trabalho já commitado. Ele roda o pipeline, faz o pipeline aplicar correções seguras e para para perguntar a você sobre qualquer coisa que exija uma decisão humana.

O `drill init` instala a skill `/drill` para o Claude Code e outros agentes.
Por baixo dos panos, a skill conduz o `drill axi`, uma interface TOON não interativa para o mesmo fluxo de aprovação.

Veja o [início rápido](https://github.com/runecraftai/squad/tree/main/packages/drill/docs/src/content/docs/start-here/quick-start.md) para o passo a passo completo da primeira execução.

## Desenvolvimento

```sh
make build   # Compila bin/drill com informações de versão
make test    # Roda go test -race ./... (exclui a suíte e2e)
make e2e     # Roda a suíte e2e de jornada do agente, marcada por tags
make e2e-record # Regrava as fixtures e2e quando os formatos de wire do agente mudam
make lint    # Verifica drift nas skills geradas e roda go vet ./...
make skill   # Regenera os arquivos de skill do drill já commitados
make fmt     # Roda gofmt -w .
make demo    # Regenera demo.gif e demo.mp4 (precisa de vhs e ffmpeg)
make docs    # Compila o site de documentação Astro em docs/dist
```

Veja o `Makefile` para a lista completa de targets.

O `make e2e-record` sobrescreve `internal/e2e/fixtures/` usando os CLIs reais do `claude`, `codex` e `opencode`, consome cota real de API e deve ser revisado antes do commit.
