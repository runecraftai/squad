<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Públicos da documentação

[`documentation-audiences.json`](../documentation-audiences.json) é o dono da classificação consumida por máquina para toda superfície de prosa mantida.
O `bin/sq-doc-audience-check.sh` valida cobertura exata do inventário, roteamento de setup do README, ponteiros obrigatórios para donos e alvos de links locais.
Os metadados de público ficam centralizados ali em vez de copiados para o front matter de cada página.

As classes de público têm um propósito de posicionamento cada:

- `public-product` apresenta o produto ou fornece material público standalone.
- `operator-current` explica comportamento atual, setup, limites suportados, invariantes estáveis, racional conciso e pontos de entrada atuais de verificação.
- `operator-example` é material de setup atual copiável.
- `maintainer-architecture` explica posse estável, pontos de extensão, fronteiras de mecanismo e racional de segurança para contribuidores.
- `maintainer-verification` registra evidência repetível de uma garantia ativa e pode incluir datas, versões, comandos exatos e saída exata.
- `agent-runtime` é carregado ou renderizado como contrato operacional para agentes Squad em vez de lido como documentação de produto.

A política de posicionamento de conhecimento é de propriedade do [`squad-coding-guidelines`](../../.agents/skills/squad-coding-guidelines/SKILL.md).
Cronologia específica de tarefa, transcripts de entrega, caminhos temporários, branches, hipóteses falhas e identificadores de processo one-off ficam por padrão em relatórios privados de tarefa ou evidência de PR.
Antes de remover essa evidência de uma página rastreada, destile todo fato atual único para seu dono classificado e mantenha um ponteiro focado de regressão.

Rode a verificação estrutural diretamente com:

```sh
bin/sq-doc-audience-check.sh
```

A verificação deliberadamente não faz lint de datas, versões, comandos, caminhos, linguagem de incidente ou prosa parecida com transcript.
Essas formas são legítimas na verificação para mantenedores e exigem revisão semântica em vez de heurísticas de palavra-chave.
Para toda superfície de prosa alterada, revise o público dela, o dono autoritativo, a relevância atual, o destino da evidência e os fatos únicos de segurança, depois repita essa revisão sobre o diff completo da branch depois de todos os fixes.
