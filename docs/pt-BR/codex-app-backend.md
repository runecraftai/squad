<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Fronteira do backend Codex App

O Codex App não é um backend de runtime selecionável do Squad.
As host tools do Codex Desktop conseguem criar e supervisionar threads visíveis e essas threads podem escrever nos arquivos de status do Squad quando recebem um caminho autorizado, mas o Squad não tem nenhuma ponte suportada e chamável via shell para essas host tools.
Um registro manual de threads não é um backend.

## Contrato de aceitação

Um futuro backend Codex App precisa satisfazer o mesmo contrato de ciclo de vida dos adaptadores baseados em terminal:

1. Criar um endpoint de tarefa e devolver um id durável de thread.
2. Enviar as instruções iniciais e mensagens posteriores do operador para esse endpoint.
3. Ler estado vivo suficiente ou transcript limitado para supervisionar a tarefa.
4. Arquivar, matar ou de outra forma parar exatamente aquele endpoint.
5. Permitir que a thread appende as linhas normais do ciclo de vida do Squad em `state/<id>.status`.

O canal de retorno de status é obrigatório.
Uma thread visível que não consegue reportar ao ciclo de vida normal do Squad não é um backend completo.

## Bloqueio atual

Os scripts de backend do Squad são pontos de entrada shell e podem chamar tmux, Herdr, Zellij, Orca e cmux diretamente.
As host tools do Codex Desktop estão disponíveis para uma conversa do Desktop, não para subprocessos arbitrários do Squad.
O componente que falta é um transporte chamável via shell suportado pelo Codex Desktop, não outro ledger local.

`codex app-server --stdio` expõe peças úteis de JSON-RPC como thread start, turn start, thread read e thread archive.
Uma sonda de processo único poderia criar e arquivar um registro de thread, mas nenhuma ponte suportada foi encontrada que permita ao Squad criar, continuar, ler e arquivar o mesmo endpoint visível de propriedade do Desktop por todo o seu ciclo de vida.
Um proxy bruto do control socket do Desktop não é um transporte suportado.
Essas peças parciais não autorizam adicionar `codex-app` aos registros de backends conhecidos ou spawn-capables.

## Ponte necessária

A implementação pode começar depois que o Codex Desktop expuser uma interface suportada:

- um wrapper CLI para as operações de host tool create, send, read e archive;
- um transporte JSON-RPC ou MCP documentado, com framing estável; ou
- um helper mantido que fale o transporte suportado e devolva JSON puro a um adaptador shell.

A ponte precisa fornecer estas semânticas:

```text
create: task id, worktree request, initial instructions -> thread id, cwd, state
send: thread id, text -> accepted or rejected
read: thread id, bounded cursor -> transcript and live state
archive: thread id -> archived or stopped
return: thread appends state/<id>.status lifecycle lines
```

Assim que disponível, o Squad deve adicionar um `bin/backends/codex-app.sh` real, persistir `backend=codex-app` e `codex_app_thread_id=`, e rotear spawn, send, peek, watch e cleanup pelo dispatcher compartilhado.

## Rollout

Tarefas ship e recon vêm primeiro.
Suporte a XO permanece fora do escopo até que create, send, read, retorno de status e archive estejam provados pelo dispatcher normal de backends.
Até lá, o Codex App permanece uma fronteira de backend bloqueada com um registro verificado de capacidade das host tools, não um backend selecionável.

[`verification/runtime-backends.md`](../verification/runtime-backends.md#codex-app-host-tools) guarda o smoke ativo das host tools do Desktop sem expor ids de thread específicos de tarefa ou caminhos locais.
