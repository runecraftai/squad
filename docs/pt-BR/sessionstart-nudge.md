<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Adaptadores nativos de início de sessão

A seção 3 do AGENTS.md é o contrato comportamental autoritativo para o início de sessão.
Este arquivo é dono de como os adaptadores nativos rastreados de abertura de sessão a entregam, e dos limites de compatibilidade que forçam duas camadas em vez de uma.

O Squad acompanha duas camadas de abertura de sessão, e a camada é propriedade da superfície do harness, não da base.

| Camada | O que o adaptador faz | Usado por |
| --- | --- | --- |
| Run | Executa `bin/sq-session-start.sh` no hook e deixa o digest ordenado dele chegar ao contexto do modelo antes do primeiro turno. | Claude, `codex exec`, Pi / pi-signed |
| Nudge | Pede ao agente para rodar o digest pelo adaptador nativo ou pela instrução rastreada de início de sessão. | Grok, OpenCode, TUI interativa do Codex, e fontes run-tier roteadas ao nudge |

A camada run existe porque o nudge só pode pedir.
Um agente pode adiar uma instrução, inclusive quando uma skill de primeiro comando tem caminho read-only próprio.
Rodar o digest dentro do hook remove essa discrição, então até uma sessão cujo primeiro comando é uma skill já assumiu o leme.
A camada nudge permanece o piso para harnesses que não conseguem levar stdout do hook ao contexto do modelo, e nunca é um segundo contrato: ambas as camadas terminam no mesmo `bin/sq-session-start.sh`.

## Roteamento por fonte

`bin/sq-sessionstart-run.sh` é o único dono do significado de uma fonte de abertura de sessão, então nenhuma string matcher de harness precisa codificar essa política.
Ele recebe `--source <nome>` quando o adaptador conhece a fonte nativamente, e caso contrário lê o campo `source` de um payload JSON de hook em formato Claude/Codex no stdin.

| Fonte | Ação | Por quê |
| --- | --- | --- |
| `startup`, `new` | Digest completo | Este processo não assumiu o leme. |
| `clear`, `compact` | `--reemit` depois de startup provadamente completo, senão digest completo | Este processo normalmente tem o leme e perdeu apenas seu contexto, mas um hook anterior pode ter sido truncado após adquirir o lock. |
| `resume`, `reload`, `fork` | Delegar ao wrapper nudge | Contexto prévio foi restaurado, então rodar de novo é redundante quando o lock ainda é nosso e uma instrução basta quando um novo processo retomou uma sessão antiga. |
| ilegível ou não reconhecida | Digest completo | Assumir o leme redundante é barato e idempotente; não assumi-lo é o bug que esta camada existe para corrigir. |

Isto inverte deliberadamente o matcher nudge anterior, que disparava em `startup|resume|clear` e excluía `compact`.
Compactação agora está coberta porque uma sessão compactada perdeu exatamente o digest de que precisa, e resume agora é excluído do run porque restaura aquele digest em vez de perdê-lo.

A posse atual do lock pelo harness e o registro correspondente `state/.session-start-complete`, juntos, são o interlock de idempotência de todo o esquema.
O digest completo limpa aquele registro de conclusão depois de adquirir o lock e republica o pid do dono do lock apenas depois que todo estágio completa, então `clear` ou `compact` não pode pular varreduras de startup após execução truncada.
`bin/sq-lock.sh` já trata um lock que o próprio harness desta sessão detém como dele próprio, então um re-emit provado de `clear` ou `compact` reverifica a posse e prossegue, enquanto um lock tomado enquanto isso por outra sessão viva ainda produz o digest ordinário read-only.
Num harness run-tier o nudge também não dispara: `resume`, `reload` e `fork` são as únicas fontes roteadas a ele, e nessas sua própria checagem de ancestralidade fica silenciosa sempre que este processo já detém o lock.

`bin/sq-session-start.sh --reemit` é dono de qual trabalho um re-emit pula; seu cabeçalho é o único dono dessa lista.

## Limite de runtime

A camada run bloqueia a inicialização da sessão enquanto o digest roda, então `bin/sq-session-start.sh` limita a si mesmo em vez de apostar no timeout de hook próprio de cada harness.
O digest não faz chamada externa de rede nenhuma: cada uma que deve rodar executa concorrentemente no estágio diferido limitado separadamente de propriedade de `bin/sq-startup-network.sh`, então um host inalcançável não pode mais consumir esse orçamento.
O que resta ainda não é individualmente limitado - sondas de versão de ferramentas, a listagem do backlog e as leituras de endpoint por tarefa são todos subprocessos locais porém sem limite - então o digest inteiro roda como um único filho limitado, padrão 120s via `SQUAD_SESSION_START_TIMEOUT`.
O dono compartilhado de timeout recua para um watchdog de grupo de processos em pure-Bash quando timeout, gtimeout e perl estão indisponíveis, então nenhum host suportado roda o digest sem limite.
Como o filho escreve direto no stdout do hook, tudo emitido antes de bater o limite já foi entregue; o pai então imprime um banner `STARTUP TRUNCATED` nomeando o estágio que não terminou e os estágios que portanto nunca foram emitidos, e mesmo assim sai 0.
Os timeouts registrados dos hooks ficam acima desse orçamento para que o harness nunca preempte o banner.
O estágio de rede diferido deliberadamente roda no próprio grupo de processos dele sob deadline própria, então um digest truncado nem mata trabalho que não esperava nem órfã trabalho de rede ilimitado.

## Wrapper compartilhado e segurança

`bin/sq-sessionstart-run.sh` e `bin/sq-sessionstart-nudge.sh` compartilham os mesmos dois donos de elegibilidade.
Eles carregam (source) `bin/sq-gate-refuse-lib.sh` e ficam silenciosos para um agente gate drill identificado por `DRILL_GATE` ou um git-common-dir `.drill/repos/*.git`.
Eles compartilham `bin/sq-primary-scope-lib.sh` com `bin/sq-turnend-guard.sh`, então todo hook usa um único dono de detecção primária.
A seção Guard Predicates de [`turnend-guard.md`](../turnend-guard.md#guard-predicates) é dona da validação de marcadores, detecção de checkout simples e paths exigidos em formato Squad.

O payload do nudge começa com U+2063 e o rótulo estável `SQUAD_OP: `, carrega o kind atual `session-start`, e mantém exatamente ``Run `bin/sq-session-start.sh` now, exactly once, before executing any other instructions.`` como corpo.
A skill Reporting é dona da regra de que este input operacional marcado nunca é fronteira de sessão escrita pelo comandante, incluindo seus casos estreitos legados de compatibilidade, e sua própria checagem step 0 de leme é o fallback que protege um harness nudge-tier cujo primeiro comando é uma skill.

Antes de imprimir, o wrapper nudge lê `state/.lock` e caminha no máximo oito pais a partir do próprio pid num loop próprio separado e hard-coded, independente da caminhada de ancestralidade de `bin/sq-lock.sh` (`fm_harness_ancestry_pid()` em `bin/sq-session-lock-lib.sh`, que agora caminha até dezesseis pais e pode estender além de um match nomeado claude até um ainda mais ancestral) e do `lockOwnership()` do Pi.
Se o lock nomeia um pid vivo naquela ancestralidade, o início de sessão já rodou nesta sessão de harness e o wrapper fica silencioso.
Todo caminho em ambos os wrappers sai 0, incluindo estado malformado e erros de adaptador, porque um exit 2 de SessionStart do Claude bloqueia a inicialização da sessão.
Um lock detido por outra sessão e um digest truncado portanto aparecem como texto do digest, enquanto auth GitHub quebrada aparece através do resultado da rede diferido inline ou como acordo; nenhum vira recusa de abrir a sessão.

## Transportes por harness

| Harness | Camada | Transporte rastreado | Compatibilidade atual |
| --- | --- | --- | --- |
| Claude | Run | `.claude/settings.json` registra um hook `SessionStart` sem match, invocado via `CLAUDE_PROJECT_DIR` com timeout de 180s; o wrapper lê `source` do payload do hook. | Injeção nativa de contexto via stdout é suportada. |
| Codex exec | Run | `.codex/hooks.json` ancora ao diretório de trabalho do processo do hook, verifica uma raiz Squad portadora do hook e canaliza o payload do hook para o wrapper com timeout de 180s. | Injeção nativa de contexto via stdout é suportada sob `codex exec`. |
| Codex interactive TUI | Nudge | A instrução rastreada de início de sessão do `AGENTS.md` e o fallback step-zero do Reporting permanecem visíveis quando o hook de projeto não dispara. | Codex 0.146.0 não dispara o hook `SessionStart` de projeto rastreado na TUI interativa dele. O Squad não acompanha hook global e não depende de um. |
| Pi / pi-signed | Run | `.pi/extensions/sq-primary-turnend-guard.ts` mapeia razões `session_start` `startup`, `new`, `resume` e `fork` para fontes do wrapper, trata `session_compact` como equivalente à compactação, e injeta a saída com `pi.sendMessage`. | A mensagem customizada chega ao contexto do modelo sem correr contra um prompt posicional inicial. A razão `reload` do Pi fica deliberadamente sem mapeamento, como sempre esteve. |
| OpenCode | Nudge | `.opencode/plugins/sq-primary-sessionstart-nudge.js` escuta `session.created`, roda uma vez por id de sessão, e chama `client.session.promptAsync` apenas quando o wrapper imprime um nudge. | Entrega na TUI interativa é suportada; `opencode run` headless é deliberadamente fail-open porque o processo pode sair antes do turno enfileirado. Essa saída precoce é também por que o OpenCode não consegue usar a camada run. |
| Grok | Nudge | `.grok/hooks/sq-primary-sessionstart-nudge.json` registra um hook `SessionStart` de projeto e invoca o wrapper via `${GROK_WORKSPACE_ROOT:-}` com defaults inline. | O hook de projeto roda quando o checkout é confiável, mas o Grok atualmente descarta stdout de hooks fora do contexto do modelo, então este caminho é deliberadamente fail-open e não pode usar a camada run. |

Pi é o único adaptador que injeta uma mensagem em vez de stdout de hook, então o que ele injeta precisa carregar proveniência operacional ou a skill Reporting teria que adivinhar se foi escrito pelo comandante.
A extensão portanto codifica um digest sem encoding como input operacional `session-start` antes de enviá-lo, e deixa o nudge já codificado em paz.
Ela transmite o hook até completar e retém no máximo 512 KiB para entrega da mensagem; essa contenção aprovada mantém o prefixo e appenda um marcador ruidoso `PI SESSION-START DELIVERY TRUNCATED` com orientação de inspeção direta sempre que o digest estiver incompleto.

O nudge do OpenCode roda apenas em `session.created`.
Os plugins sentry-arm e turn-end rodam depois em `session.idle`, e o guard deixa o coordenador de sentinela agir primeiro, então os plugins não correm pelo mesmo evento de ciclo de vida.

A alternativa garantidamente carregada do Grok seria um hook global protegido por token como o padrão usado por `bin/sq-spawn.sh`.
Essa alternativa expande confiança e escreve fora deste repositório, então o Squad nunca a instala nem concede confiança de pasta automaticamente.

## Cobertura de regressão

`tests/sq-sessionstart-nudge.test.sh` prova o silêncio do wrapper nudge para ambos os sinais de gate, um worktree linkado sem marca, um diretório de estado ausente e um lock já detido, mais sua saída exata de uma linha prefixada com U+2063 `SQUAD_OP:` e tipada `session-start`.
Ele prova separadamente o silêncio do wrapper run para o ambiente de gate e um worktree linkado sem marca.
Ele prova o roteamento por fonte do wrapper run end-to-end contra um real `sq-session-start.sh`, incluindo seleção `--reemit` condicionada à conclusão, delegação de resume, uma fonte não reconhecida caindo para o digest completo, e entrega ruidosa limitada de um digest Pi oversized.
`tests/sq-session-start.test.sh` prova o limite de runtime através do fallback pure-Bash forçado: um digest resistente a TERM que excede seu orçamento é morto à força junto do neto, ainda emite seus estágios completados, nomeia o estágio incompleto e todo estágio que nunca alcançou, deixa nenhuma prova de conclusão e sai 0.
`tests/sq-pi-primary-live-e2e.test.sh` e `tests/sq-opencode-primary-live-e2e.test.sh` exercitam caminhos nativos de startup com regressões de Reporting de primeira-mensagem e mensagem-posterior.
`tests/sq-sessionstart-hook-live-e2e.test.sh` é o guard live opt-in que confirma que cada adaptador run-tier instalado invoca o wrapper run e entrega a saída dele ao contexto.
Ele verifica a fonte reopen preservadora de contexto para todo harness run-tier instalado e a entrega reset-de-contexto onde quer que a superfície TUI rastreada seja alcançável.
`tests/sq-turnend-guard.test.sh`, `tests/sq-pi-watch-extension.test.sh` e `tests/sq-daemon.test.sh` cobrem entrega de guard marcado, monitoramento e modo ausente.

[`verification/supervision.md`](../verification/supervision.md#native-session-start-delivery) registra a evidência ativa de transporte com escopo de versão.
