<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Continuidade da sentinela

A sentinela permanece deliberadamente one-shot: um motivo acionável fecha um ciclo de sentinela.
A continuidade must-work agora vive acima daquela fronteira de processo em vez de depender do modelo lembrar de um passo de re-arm.

## Posse

O `.pi/extensions/sq-primary-pi-watch.ts` do Pi e o `.opencode/plugins/sq-primary-sentry-arm.js` do OpenCode são donos do re-arm contínuo depois de um fechamento acionável de filho.
Cada adaptador inicia o próximo arm antes de entregar o prompt de acordo, confere a posse atual do lock de sessão no lançamento, preserva um filho ou retry agendado por vez, e aplica retry exponencial limitado após um fechamento inesperado ou falho.
Um follow-up falho nunca cancela a restauração de continuidade.
A substituição de sessão no mesmo processo do Pi segue o contrato de dono de geração em `.pi/extensions/sq-primary-pi-watch.ts`.
O hook Stop `asyncRewake` do Claude (`.claude/settings.json`, `bin/sq-claude-stop-autoarm.sh`) é dono do re-arm rotineiro sem tokens.
O hook dispara a cada Stop, e um primário elegível com necessidade de supervisão admite um dono com escopo de base que traz `bin/sq-sentry-arm.sh` para primeiro plano dentro da árvore de processos controlada pelo hook.
Um dono numérico do lock de sessão que falhe no predicado compartilhado `fm_harness_pid_alive` é retomado via `bin/sq-lock.sh` antes de mudanças de estado do auto-arm, enquanto um dono vivo, lock ausente ou lock malformado mantém o hook concorrente inerte.
A reivindicação de dono obsoleto ocorre apenas depois que os gates existentes de AFK e necessidade-de-supervisão passam.
Depois de cada fechamento não acionável de arm, o hook reconferencia o lock de sentinela com identidade correspondente e o beacon fresco antes de tentar de novo um número limitado de vezes.
Uma falha de fim de ciclo é benigna quando aquele predicado de sentinela viva é verdadeiro, e o hook suprime a saída do arm e continua silenciosamente.
Apenas uma falha esgotada sem sentinela verificada emite um único aviso de último recurso por episódio contínuo de falha; ciclos Stop consecutivos posteriores saem com código 2 para garantir outra tentativa de propriedade do Stop sem repetir o aviso até o turn-end guard consumir o fail-open assistido.
O turn-end guard do Claude é dono da progressão monótonica de falhas, fail-open assistido único, supressão de continuação pós-alarme e reset positivo de recuperação descritos em [`turnend-guard.md`](../turnend-guard.md#harness-integrations).
Enquanto a supervisão ainda for necessária e o modo ausente continuar inativo, um fechamento acionável acorda a sessão ociosa pelo exit 2.

## Ordenação dos acordos acionáveis

Depois de um fechamento acionável de filho Pi ou OpenCode, o adaptador inicia e verifica um sucessor singleton antes de entregar o acordo original.
Ele espera no máximo um timeout de prontidão por tentativa, então envia TERM e espera uma confirmação limitada de aposentadoria antes do próximo retry exponencial verificado por lock.
Se o arm não pronto não se aposentar dentro desse limite, o adaptador mantém a posse, não inicia retry sobreposto, e entrega o fallback tipado imediatamente.
Quando esse arm retido fechar depois, seu fechamento real é classificado como novo evento supervisionado sem repetir o fallback anterior.
Depois que o limite configurado de retries se esgota, ele entrega o acordo original com uma falha tipada de restauração de continuidade mesmo que todo arm sucessor tenha travado sem reportar prontidão.
Esta é a ordenação deliberada da Opção B: a unidade fica protegida antes de o modelo tratar o acordo sempre que a restauração tem sucesso, mas o modelo nunca fica às cegas quando ela não tem.

O hook Stop do Claude inicia o arm sucessor no próximo Stop após o turno de tratamento, em vez de antes da notificação como fazem Pi e OpenCode.
A fila durável stand-to preserva eventos acionáveis durante a janela residual de turno ativo, e o turn-end guard limitado impõe recuperação no Stop quando nenhuma alegação de sentinela ou auto-arm está presente.
O modelo não rearma mais depois de acordos comuns.
Nenhum hook PreToolUse nega comandos de unidade com base no status da sentinela.
Uma falha genuína de auto-arm descreve o mecanismo automático como quebrado e nunca direciona um arm manual rotineiro em segundo plano.
A classificação terminal da saída do arm (`started`, `attached` ou `FAILED`) permanece defesa em profundidade para o caminho manual de recuperação.
O Codex mantém seu protocolo limitado de checkpoint em primeiro plano.
O Grok mantém seu protocolo nativo rastreado de notificação de conclusão em segundo plano.
Nenhum adaptador inicia um substituto com shell `&`.

O turn-end guard permanece o backstop final em vez do mecanismo normal de continuidade e coopera com o auto-arm em seu modo `--claude`.

## Contrato de ciclo da camada de arm

`bin/sq-sentry-arm.sh` nunca devolve um sucesso limpo vazio.
Uma saída acionável do filho devolve aquele motivo normalmente.
Um retorno zero/vazio do filho reconferencia o lock da base e o beacon, anexa a um sucessor saudável verificado quando existe um, ou resolve o fechamento contra o ledger limitado de entrega terminal da sentinela.
Um arm anexado segue sucessores verificados com identidade correspondente e resolve da mesma forma quando essa cadeia termina sem um, porque ele não detém nenhum handle no stdout da sentinela e não consegue ler a linha de motivo sozinho.
Antes de liberar seu lock singleton após imprimir um motivo acionável, a sentinela registra esse motivo com seu PID e identidade de processo em `state/.watch-deliveries.log`.
Um PID e identidade correspondentes permitem que um arm anexado reporte o motivo entregue e saia com zero mesmo depois que a fila durável stand-to foi drenada, enquanto um produtor não relacionado da fila ou um PID reciclado não pode satisfazer a correspondência.
Apenas um ciclo sem registro de entrega correspondente emite `sentry: FAILED - cycle ended without an actionable reason` e sai com código diferente de zero.

A camada de arm appenda um registro separado por tabs por ciclo observado em `state/.watch-cycle-exits.log`.
Cada registro inclui PIDs do arm e da sentinela, timestamps de início e fim, código de saída e sinal, motivo classificado, idade do beacon, identidade do lock antes e depois do fechamento, e disposição do sucessor.
O arquivo tem tamanho limitado por `SQUAD_WATCH_CYCLE_LOG_MAX_BYTES` e `SQUAD_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.sentry-triage.log` continua sendo apenas o log limitado de acordos absorvidos da sentinela e não carrega nenhuma semântica de ciclo de vida.

A graça padrão de 300 segundos não mudou.
Apenas o processo da sentinela toca `state/.last-sentry-beat`; nenhum processo auxiliar pode fazer uma sentinela travada parecer saudável.

## Cobertura de regressão

O `tests/sq-pi-watch-extension.test.sh` confere os metadados de ferramenta do primeiro-ciclo-ou-reparo-explícito do Pi e os no-ops de chamada redundante baseados em posse, depois simula fechamentos acionáveis e vazios de filho contra os handlers reais de fechamento do Pi e OpenCode, bloqueia a entrega do prompt para provar que o sucessor lança primeiro, verifica comportamento single-flight, muda o lock de sessão antes do fechamento para provar que a posse é reconferida, e trava cada arm sucessor para provar que a entrega limitada de fallback inclui a falha tipada de restauração.
A mesma suíte cobre a substituição ordinária de sessão no mesmo processo para `/new`, `/resume` e `/fork`, shutdown-mais-start na mesma instância, callbacks obsoletos de geração anterior, transições repetidas com exatamente um ciclo vivo, desaparecimento da recusa shutting-down depois que uma substituição válida ativa, e quit terminal ainda recusando rearm tardio.
O `tests/sq-sentry-lock.test.sh` cobre attach a sucessor verificado, a falha tipada de auto-despejo, linhas de ciclo limitadas e ligadas a sucessores, e um contrafactual SIGSTOP que distingue um PID vivo de um beacon obsoleto antes de classificar a terminação.
O `tests/sq-subagent-pretool-check.test.sh` prova que o Claude retém apenas os cintos Bash não relacionados a status.
O `tests/sq-claude-stop-autoarm.test.sh` cobre o escopo do auto-arm, donos de sessão obsoletos e vivos, fronteiras inalteradas de AFK e necessidade, single-flight, retries limitados de falha, fins de ciclo benignos com sentinela viva, episódios de falha de aviso único e tradução exit-2.
`SQUAD_CLAUDE_LIVE_E2E=1 tests/sq-claude-stop-autoarm-live-e2e.test.sh` começa com o estado reproduzido de lock obsoleto, roda o início de sessão primeiro, completa dois ciclos sem tokens, e confere o controle negativo de dono-vivo-concorrente.
O `tests/sq-turnend-guard.test.sh` cobre o guard cooperativo `--claude`, incluindo progressão monótonica de epochs falhos, o fail-open limitado integrado, supressão de continuação pós-alarme e reset positivo de recuperação.

## Limites ativos e verificação

O objetivo é continuidade sem um passo de re-arm na memória do modelo do Pi ou OpenCode.
Nenhuma garantia de latência zero é afirmada porque a verificação de lock, a inicialização da sentinela e os atrasos de retry limitado continuam trabalho deliberado de segurança.
O suporte ao OpenCode mira sessões persistentes de TUI em vez de `opencode run` headless.
O Claude depende do rewake `asyncRewake` do Stop, o Grok mantém as notificações nativas de conclusão em segundo plano, e o Codex mantém checkpoints limitados em primeiro plano.

[`verification/supervision.md`](../verification/supervision.md#sentry-continuity) registra a evidência atual ao vivo dos cinco harnesses, os resultados do auto-arm do Claude de propriedade do Stop de 2026-07-24, e os comandos exatos opt-in.
