# Backup Minecraft (SFTP -> ZIP -> Destino via rclone)

Este repositório/arquivo contém um script PowerShell (`backup-mc.ps1`) para:

- Baixar (sincronizar) o mundo do Minecraft via SFTP para uma pasta local.
- Compactar tudo em um `.zip`.
- Enviar o `.zip` para um destino configurado no `config.json` (via `rclone` ou pasta local).
- Manter apenas os **7 backups mais recentes** no remoto (rotação).

## Por que esse script existe

Backups de servidor de Minecraft costumam falhar por motivos comuns:

- Falhas de rede/intermitência no SFTP.
- Upload interrompido para o armazenamento remoto.
- Execuções simultâneas (Agendador do Windows rodando 2x) gerando backups corrompidos ou rotação removendo arquivos na hora errada.
- Scripts que “seguem em frente” mesmo com erro (backup aparentemente ok, mas incompleto).

Este script foi ajustado para ser **mais resiliente e auditável**:

- **Fail-fast**: se um passo crítico falhar, o script para e deixa claro no log.
- **Retry**: tenta novamente operações do `rclone` quando há falhas.
- **Lock**: evita duas execuções ao mesmo tempo.
- **Log em arquivo**: facilita auditoria e troubleshooting.

## Requisitos

- Windows (PowerShell) ou Linux (PowerShell 7 `pwsh`).
- `rclone` instalado e disponível no `PATH`.
- 7-Zip:
  - Windows: 7-Zip instalado (por padrão em `C:\Program Files\7-Zip\7z.exe`).
  - Linux: `7z` disponível no PATH (ex.: `p7zip`).
- `rclone config` com:
  - Um remote SFTP (ex.: `sftp_bedhost:`)
  - Um remote de destino (ex.: `backblaze:` / `gdrive:` / `s3remote:`)

## Configuração (`config.json`)

O script lê um arquivo `config.json` na mesma pasta do `backup-mc.ps1`.

1. Copie o exemplo:

   - `config.json.example` -> `config.json`

2. Ajuste os campos necessários (especialmente o destino).

### Compressão do ZIP (7-Zip)

O nível de compressão é controlado por `zip.compression` e é repassado ao 7-Zip como `-mx=N`.

Valores típicos do 7-Zip para ZIP:

- Mínimo: `0` (sem compressão, mais rápido, arquivo maior)
- Máximo: `9` (compressão máxima, mais lento, arquivo menor)

Recomendação prática:

- `0-1`: quando você quer velocidade e já comprime pouco.
- `2-5`: equilíbrio entre tempo e tamanho.
- `7-9`: quando tamanho importa mais que tempo (pode aumentar bastante a duração).

Teste de integridade do ZIP:

- `zip.skipTest` (boolean)
  - `false` (padrão): roda `7z t` para validar o arquivo antes do upload.
  - `true`: pula o `7z t`.

Observação: pular o teste deixa o backup mais rápido, mas você pode só descobrir um ZIP corrompido depois (ex.: no restore).

### Retenção (quantas cópias manter)

Você pode controlar separadamente quantas cópias manter:

- Localmente (pasta de arquivos `.zip`)
- No destino configurado (remoto via `rclone`)

Campos:

- `retention.localKeep`
  - Quantos ZIPs manter no diretório `work.localArchiveDir`.
  - `0` = não manter cópias locais.
- `retention.remoteKeep`
  - Quantos ZIPs manter no destino.
  - `0` = desativa upload e rotação no destino.

Compatibilidade:

- `work.keep` é um campo **legado** (antes era a única retenção).
- Se `retention.remoteKeep` estiver definido, ele tem prioridade e `work.keep` é ignorado.

Diretório local de arquivos:

- `work.localArchiveDir`
  - Onde o script salva as cópias locais (quando `retention.localKeep > 0`).

Exemplos comuns:

- Manter **0 local** e **7 no remoto**:
  - `localKeep = 0`, `remoteKeep = 7`
- Manter **7 local** e **0 remoto**:
  - `localKeep = 7`, `remoteKeep = 0`

### Destinos suportados (provider)

Em `destination.provider`, escolha um dos valores:

- `b2` (Backblaze B2 via remote type `b2`)
- `gdrive` (Google Drive via rclone)
- `s3` (S3-compatível via rclone)

#### Importante: Backblaze B2 exige bucket

Se você usa uma application key restrita a um bucket, o caminho de destino precisa ser do tipo:

- `backblaze:<BUCKET>/<prefix>`

Por isso, quando `provider=b2`, o `config.json` **obriga** preencher `destination.b2.bucket`.

## Como usar

É necessário habilitar a execução de scripts no PowerShell, por padrão o Windows bloqueia a execução de scripts, para isso:

1. Abra o PowerShell como Administrador.
2. Rode o script:

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File "backup-mc.ps1"
```

Para ignorar o `backup.lock` (modo forçado, útil em testes quando uma execução anterior foi interrompida):

```powershell
powershell -ExecutionPolicy Bypass -File "backup-mc.ps1" -IgnoreLock
```

### Linux

```bash
pwsh ./backup-mc.ps1
```

Modo forçado (ignorar lock):

```bash
pwsh ./backup-mc.ps1 -IgnoreLock
```

### Recomendações

- Agende no **Agendador de Tarefas do Windows**.
- Não rode manualmente enquanto o agendador pode disparar (o lock vai bloquear e o script irá falhar de propósito).

## Rodando em VPS ou PC de casa (automação)

Rodar o backup em uma VPS ou em um PC/servidor de casa é uma boa opção quando você quer:

- Ter uma máquina sempre ligada.
- Ter mais estabilidade de rede para o upload.
- Centralizar logs/monitoramento.

Pontos de atenção:

- Garanta espaço suficiente no disco para `sync_dir` + o `.zip`.
- Use um usuário dedicado.
- Monitore o exit code e/ou os logs.

### Agendamento no Linux (cron)

Exemplo (rodar todo dia às 03:00):

```cron
0 3 * * * /usr/bin/pwsh /caminho/para/backup-mc.ps1
```

Se preferir, você também pode usar `systemd timers`.

### Agendamento no Windows (Agendador de Tarefas)

Passo a passo (GUI):

1. Abra o **Agendador de Tarefas**.
2. Clique em **Criar Tarefa...** (evite "Criar Tarefa Básica" para ter mais opções).
3. Aba **Geral**:
   - Nome: `Backup Minecraft`
   - Marque **Executar estando o usuário conectado ou não**.
   - Opcional: marque **Executar com privilégios mais altos**.
4. Aba **Disparadores**:
   - **Novo...**
   - Agendar diário/horário desejado.
5. Aba **Ações**:
   - **Nova...**
   - **Programa/script**:
     - `powershell.exe`
   - **Adicionar argumentos**:
     - `-NoProfile -ExecutionPolicy Bypass -File "C:\\caminho\\para\\backup-mc.ps1"`
     - Opcional: adicionar `-IgnoreLock` quando você quiser modo forçado.
   - **Iniciar em**:
     - `C:\caminho\para` (a pasta onde está o `backup-mc.ps1` e o `config.json`)
6. Aba **Condições**:
   - Ajuste conforme seu cenário (ex.: desmarcar "Iniciar a tarefa somente se o computador estiver em CA" em notebook).
7. Aba **Configurações**:
   - Recomendo marcar:
     - **Se a tarefa falhar, reiniciar a cada** (ex.: 10 min) por X tentativas.
     - **Parar a tarefa se ela for executada por mais de** (ex.: 12 horas), se fizer sentido.

Observação: o script grava logs em `work.tempDir/logs` e retorna exit codes úteis para monitoramento.

### Agendamento no Linux (systemd service + timer)

Exemplo de unit para rodar o script via `pwsh`.

1. Crie o service (ex.: `/etc/systemd/system/backup-minecraft.service`):

```ini
[Unit]
Description=Backup Minecraft (SFTP -> ZIP -> destination)

[Service]
Type=oneshot
WorkingDirectory=/caminho/para/backups_minecraft_windows
ExecStart=/usr/bin/pwsh /caminho/para/backups_minecraft_windows/backup-mc.ps1
```

2. Crie o timer (ex.: `/etc/systemd/system/backup-minecraft.timer`):

```ini
[Unit]
Description=Agendamento do Backup Minecraft

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

3. Ative:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backup-minecraft.timer
sudo systemctl list-timers | grep backup-minecraft
```

Para rodar manualmente:

```bash
sudo systemctl start backup-minecraft.service
```

## Onde ficam os logs

Os logs são gravados por exemplo em:

- `G:\BackupsMC\logs\backup_minecraft_YYYY-MM-DD_HH-mm.log`

Esses logs registram:

- Caminhos de origem/destino.
- Tentativas e falhas de comandos do `rclone`.
- Mensagens de erro com causa provável.

## Exit codes (para Agendador de Tarefas / monitoramento)

O script retorna códigos de saída específicos. Isso é útil para você diferenciar falhas no Agendador de Tarefas.

- **0**: Sucesso.
- **1**: Falha desconhecida (não classificada).
- **2**: Execução bloqueada por lock (`backup.lock`).
- **3**: Dependência ausente (`rclone`/`7-Zip`).
- **10**: Falha do `rclone` (sync/list/upload/delete).
- **11**: Falha do 7-Zip (compactação/teste do ZIP).

## Como funciona (visão geral)

1. **Validações**
   - Verifica se `rclone` existe no `PATH`.
   - Verifica se o `7z.exe` existe no caminho configurado.

2. **Lock de execução**
   - Cria `backup.lock`.
   - Se já existir, aborta para evitar execução concorrente.

3. **Sync SFTP -> Local**
   - Usa `rclone sync` para manter um espelho local do SFTP.
   - Exclui `logs/**` e `cache/**`.

4. **Compactação**
   - Cria um ZIP com timestamp (`backup_minecraft_YYYY-MM-DD_HH-mm.zip`).
   - Valida o ZIP localmente com `7z t` antes do upload.

5. **Upload para destino**
   - Garante a pasta (`rclone mkdir`) e faz `rclone move`.

6. **Rotação**
   - Lista o remoto com `rclone lsl`.
   - Ordena por data/hora real.
   - Mantém apenas os **7** mais recentes.
   - Deleta somente arquivos `backup_minecraft_*.zip` usando `rclone deletefile`.

## Por que usar `lock`

Sem lock, duas execuções simultâneas podem:

- Compactar enquanto a pasta `sync_dir` está sendo atualizada.
- Subir ZIP parcial.
- Apagar backups enquanto um upload ainda está ocorrendo.

O lock é propositalmente “chato”: se existir, o script falha com mensagem clara.

## Por que usar retry

O `rclone` já tem retries internos, mas o script também:

- Reexecuta comandos críticos do `rclone` quando há falhas.
- Ajuda em erros transitórios (rede/timeout).

## Limitações importantes (Minecraft)

Mesmo com esse script, existe uma limitação natural:

- Se o servidor estiver **gravando o mundo** enquanto você copia arquivos, pode haver inconsistência.

Se você tiver controle do servidor, o ideal é pausar/forçar flush do save antes de copiar (isso não está automatizado aqui, porque depende de como você acessa o console do servidor).

## Troubleshooting

- Erro de `rclone` não encontrado:
  - Instale o rclone e garanta que `rclone` funcione no PowerShell.

- Erro de `7-Zip` não encontrado:
  - Instale o 7-Zip ou ajuste `$Caminho7Zip`.

- Erro de `Lock encontrado`:
  - Significa que já existe execução em andamento ou a última morreu.
  - Verifique se existe um PowerShell rodando o backup.
  - Se tiver certeza que não tem nada rodando, apague manualmente `G:\BackupsMC\backup.lock`.

- Falhas intermitentes:
  - Verifique conectividade com o SFTP.
  - Verifique permissões no remoto (Backblaze).
  - Consulte o log para ver em qual etapa falhou.
