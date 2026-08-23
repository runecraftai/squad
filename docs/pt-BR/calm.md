<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Modo Calm do Pi

O Calm é um toggle de apresentação de conversa exclusivo do Pi.
Ele fica desligado por padrão, e a última escolha de `/calm` persiste para a base Squad efetiva entre inícios e resumes de sessão Pi.

Enquanto o Calm está ativo e uma execução do agente está em andamento, o Calm esconde a linha `Working...` embutida do Pi e mostra no lugar um pequeno barco animado de duas linhas, sem adicionar nenhuma linha separada de status do Calm.
A água preenche a largura utilizável em azul ANSI padrão e o barco completo é amarelo ANSI padrão.
O barco é deliberadamente calmo: move uma coluna a cada 880ms, enquanto a água ondula com cadência própria mais rápida para que a superfície permaneça viva entre os passos do barco.
A vela principal é direcional, mostrando `<|` quando viaja para a direita e `|>` quando viaja para a esquerda, e vira no frame exato em que o barco faz a curva em qualquer borda.
Todo resize reflowa o sprite sem quebrar linha, e ele desaparece quando a execução se estabiliza, aborta ou falha.
Dentro de uma mesma sessão Pi e tempo de vida da extensão Calm, o próximo período de trabalho retoma o barco da última coluna renderizada e direção de viagem em vez de recomeçar na borda esquerda.
O tempo decorrido oculto não avança a animação, e um resize enquanto oculto prende o barco congelado na nova largura sem mudar sua direção válida de viagem.
Uma sessão Pi nova ou novo tempo de vida da extensão Calm começa na posição inicial normal.
Terminais muito estreitos recuam para um sprite determinístico menor.
Com o Calm desligado, a linha de trabalho padrão do Pi fica exatamente como o Pi a renderiza.
O Calm esconde rótulos de thinking colapsados, as cascas das ferramentas embutidas do Pi que o Calm controla, a casca da ferramenta `sq_watch_arm_pi` e linhas de usuário operacionais do Squad classificadas canonicamente.
Os inputs operacionais continuam sendo mensagens comuns de papel usuário, enquanto o layout de transcript do Pi renderiza suas linhas completas com altura zero.
O nudge de início de sessão continua pelo seu caminho existente de mensagem customizada não exibida.

Fora da colisão descrita abaixo com o override embutido de mesmo nome do Pi, o Calm muda apenas a apresentação.
Os wrappers embutidos do Calm preservam o comportamento de execução do Pi, e a entrega e ordenação de inputs, contexto do modelo, armazenamento de sessão, diagnósticos e operação de `/export` e `/share` permanecem inalterados.
Todo input oculto do Squad permanece disponível ao modelo e nos dados serializados da sessão e artefatos exportados.
Mensagens customizadas operacionais legadas permanecem nos dados da sessão e na árvore lateral do Pi, embora o transcript HTML principal possa omiti-las.
Desligar o Calm restaura a renderização comum, e o estado de expansão do `Ctrl+O` é preservado.

A API de apresentação suportada pelo Pi não expõe um filtro global de transcript.
Raciocínio expandido e seu espaçamento reservado, imagens de ferramentas embutidas, linhas user-bash, linhas de skill e summary, avisos genéricos de status e linhas arbitrárias de ferramenta customizada ou extensão permanecem visíveis.
Essas são fronteiras da API suportada, não falhas de conteúdo oculto.

## Compatibilidade com o Pi

O Calm não tem mínimo nem máximo numérico de versão do Pi e nunca recusa o Pi só porque sua versão é mais nova que uma versão previamente verificada.
Os adaptadores de apresentação de thinking-colapsado e de linha-de-usuário-operacional sondam a costura exata da API do Pi que eles patcham quando o Calm carrega.
Se o Pi remover uma dessas costuras, o Calm registra um diagnóstico nomeando o adaptador indisponível e pula apenas aquele adaptador; `/calm`, o outro adaptador e extensões Pi não relacionadas continuam disponíveis.

A apresentação de ferramentas embutidas do Calm (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) compartilha com qualquer outra extensão que sobrescreva a mesma ferramenta o único slot de override não mesclado do Pi por nome.
Enquanto a preferência persistida do Calm está desligada, o Calm não registra nenhum desses overrides e portanto não contesta nenhum nome de ferramenta embutida.
Na primeira vez que o Calm liga em uma sessão que começou desligado, ele reivindica todo nome embutido que nenhuma outra extensão já possua, deixa toda ferramenta contestada intacta e chamável, e exibe um warning proeminente nomeando as ferramentas que pulou.
Linhas de tool-call já na tela antes desse primeiro toggle não colapsam retroativamente; linhas posteriores dos nomes que o Calm reivindicou usam a apresentação do Calm.
Quando uma sessão inicia ou recarrega com o Calm já ligado, o Calm precisa em vez disso registrar todos os sete overrides de forma síncrona para que o Pi renderize as linhas restauradas com eles.
O Pi não oferece checagem de posse cedo o suficiente para esse caminho de load-time, e o primeiro registrante ganha a definição completa da ferramenta.
Se a outra extensão ganhar, um diagnóstico no console no início da sessão nomeia a ferramenta e a extensão vencedora; se o Calm ganhar, o Pi não expõe o registro perdedor, então o override da outra extensão fica indisponível e não pode ser nomeado.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) é dona da taxonomia de renderers com escopo de versão, das restrições de override embutido e da evidência empírica.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) é dona do arquivo de preferência persistido e das regras de resolução.
`.pi/extensions/lib/sq-calm-visibility.ts` é dona da política de visibilidade, `.pi/extensions/lib/sq-calm-operational-user-layout.ts` é dona do adaptador de linha operacional-de-usuário com altura zero, e `.pi/extensions/lib/sq-calm-working-ship.ts` é dona da apresentação animada de trabalho.

Pontos de entrada de regressão:

```sh
tests/sq-calm-pi-extension.test.sh
tests/sq-pi-primary-types.test.sh
SQUAD_PI_LIVE_E2E=1 tests/sq-pi-primary-live-e2e.test.sh
```
