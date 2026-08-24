<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Validação de frontend com Playwright

O Playwright é o conjunto de validação de frontend do Squad em três formas: um servidor MCP para validação interativa dentro do harness do agente, uma CLI para verificações pontuais via script, e um padrão de CI no lado do projeto para validação visual automática de PRs.
O [README do playwright-mcp](https://github.com/microsoft/playwright-mcp) e o [playwright.dev](https://playwright.dev) são donos da mecânica da ferramenta; este doc cobre qual forma usar em cada momento.

## Playwright MCP para validação interativa

O servidor MCP do Playwright já está registrado na configuração MCP do agente pi (`~/.pi/agent/mcp.json`) como `npx -y @playwright/mcp@latest`, então todo operador lançado no harness pi ganha suas ferramentas `browser_*` automaticamente.
O loop básico é `browser_navigate` para uma URL, `browser_snapshot` para ler a página como uma árvore de acessibilidade, `browser_click` e `browser_type` para agir sobre referências do snapshot, e `browser_take_screenshot` para capturar cada passo como evidência.
Snapshots são texto estruturado, não pixels, então os alvos das ações vêm da árvore e nenhum modelo de visão é necessário.
`browser_fill_form`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_console_messages` e `browser_network_requests` cobrem os extras comuns de validação.
Opções do servidor, como modo headless, canal do navegador, tamanho do viewport e sessões isoladas, pertencem ao README do playwright-mcp, não a este doc.
Use o fluxo MCP quando a validação for interativa e exploratória: percorrer um fluxo de cadastro ou checkout, preencher formulários e capturar screenshots de cada passo.
Use sq-browser (chrome-devtools) quando o trabalho for depuração ou performance: inspeção de console ao vivo, waterfalls de rede e investigação de DOM e CSS contra uma página em execução.
Para navegação geral pontual que não é nenhuma dessas, o sq-browser continua sendo o padrão eficiente em tokens.

## Playwright CLI para validação via script

A CLI roda sob demanda via npx, sem setup no projeto.
`npx playwright screenshot --full-page <url> <arquivo>` captura um screenshot de página inteira, e `npx playwright codegen <url>` grava interações em um teste.
Um projeto que quer validação repetível adiciona `@playwright/test` como dev dependency e roda `npx playwright install chromium` para o navegador.
A documentação de CLI e test runner do playwright.dev é dona das flags e APIs exatas.

## Validação visual automática de PRs

O padrão do lado do projeto é um job de CI que sobe a aplicação, percorre os fluxos principais com Playwright, captura screenshots de página inteira por fluxo, faz upload dos screenshots como artefatos do workflow e comenta os links das imagens no PR.
A implementação de referência é o job career-coach-pr-visual-validation no CI do runecraftai/career-coach.
