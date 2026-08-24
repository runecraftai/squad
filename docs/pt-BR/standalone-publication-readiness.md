<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Prontidão para publicação standalone

Estado de preparação para liberar os pacotes candidatos a standalone para que fiquem
utilizáveis sem o Squad. Os pacotes npm publicam sob o escopo npm `@runecraft`; os
binários Go são distribuídos como GitHub Releases compilados. Uma publicação real é
controlada pelo comandante e está fora do escopo desta mudança; este documento registra
a validação de dry-run.

## Candidatos npm

| Pacote | Versão | Dry-run | Docs desacoplados | Bloqueios |
| --- | --- | --- | --- | --- |
| `@runecraft/pr-review` | 0.2.0 | OK (`npm pack --dry-run`) | sim | nenhum |
| `@runecraft/sq-tasks` | 0.1.1 | OK | sim | nenhum |
| `@runecraft/report` | 0.1.1 | OK | sim | nenhum |
| `@runecraft/sq-gh` | 0.1.1 | OK | sim | nenhum |
| `@runecraft/sq-browser` | 0.1.1 | OK | sim | nenhum |
| `@runecraft/sq-quota` | 0.1.1 | OK | sim | nenhum |
| `@runecraft/operation-board` | 0.1.0 | OK (`npm pack --dry-run`) | sim | nenhum |

Seis dos sete candidatos npm já estão publicados nas versões atuais, então
`npm publish --dry-run` reporta "cannot publish over previously published versions"
(esperado e benigno); o novo `@runecraft/operation-board` 0.1.0 ainda não tem versão
publicada.
O `npm pack --dry-run` valida cada tarball limpo — entrypoint bin resolvendo para um
arquivo embarcado (o próprio script bash no caso do sq-board que é só script;
dist + bin para os demais) + README (+ LICENSE quando aplicável) presentes. O `pr-review`
é um pacote de extensão Pi somente-fonte cujo `scripts/verify-package-contents.mjs`
impõe uma política deliberadamente mínima de arquivos que exclui a LICENSE; mantido
como está.

A auditoria de manifestos encontrou os sete candidatos corretos (nomes, versões,
bin → dist ou arquivo embarcado, whitelist de files, sem flag `private`); nenhuma
mudança de manifesto foi necessária. Os READMEs estão desacoplados da moldura interna
do Squad mantendo as convenções de saída AXI/TOON e a marca `@runecraft`.

## Candidatos a GitHub Releases

`drill` e `fob` são distribuídos como binários compilados por OS/arquitetura anexados a
GitHub releases com tag, não via npm. A fiação de release vive nos workflows ativos na
raiz `.github/workflows/release-drill.yml` e `.github/workflows/release-fob.yml`: o
release-please cria a tag (o release do drill fica em draft até os assets anexarem), a
matriz de build compila e faz upload de arquivos por OS/arquitetura mais checksums, e o
finalize do drill publica o draft assim que todos os jobs de asset passam. Binários macOS
do drill são assinados com Developer ID no CI.

## Próximo passo (controlado pelo comandante)

A publicação real no npm é o próximo passo controlado pelo comandante. Os seis pacotes já
publicados exigem cada um um version bump (suas versões atuais já estão publicadas),
enquanto o novo `@runecraft/operation-board` 0.1.0 pode publicar na versão atual. Os
valores reais de telemetry/Team ID são necessários antes que qualquer release real de Go
seja distribuído.
