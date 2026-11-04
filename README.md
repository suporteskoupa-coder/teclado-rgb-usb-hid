# Teclado RGB via USB HID

Engenharia reversa do protocolo de iluminação de um teclado mecânico **Redragon K552-M** e um app próprio de efeitos de luz.

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=powershell&logoColor=white)
![USB HID](https://img.shields.io/badge/USB-HID-555555?style=flat)

## O problema

O software oficial do teclado tem poucos efeitos e não deixa controlar as cores direto. Para fazer efeitos próprios, era preciso descobrir **quais comandos USB** o software envia para o teclado.

## Como foi feito

1. **Captura do tráfego USB** entre o software oficial e o teclado.
2. **Análise dos pacotes:**
   - O teclado usa a interface vendor-specific **MI_02**, com reports fixos de 64 bytes.
   - Os frames de cor começam com `01 0F`. A primeira versão do app usava `01 0E` por engano, e a captura mostrou o erro.
   - Existe um *heartbeat* `01 01 00 00 00 01` enviado cerca de uma vez por segundo.
   - Pacotes sem o *padding* de zeros no final são rejeitados. A versão 0.2.1 completa os 64 bytes automaticamente.
3. **Reprodução:** o Direct HID Lab reenvia um frame capturado de verdade para separar problema de comunicação de problema na geração das cores.

## Ferramentas

**`direct-hid/`: Direct HID Lab 0.2.1**
- Conecta na interface MI_02 e envia frames de cor direto ao teclado, sem o software oficial.
- Testes de cor sólida, gradiente e replay de frame capturado.
- Não grava firmware, não instala driver e não altera arquivos do software oficial.

**`studio/`: K552-M Studio 0.4**
- Recolore em tempo real os efeitos do modo musical do software oficial.
- 6 efeitos, velocidade, brilho, saturação, suavização, gamma e calibração individual R/G/B.
- Paletas, presets e perfis salvos em JSON, com ativação automática quando o software oficial abre.

## Como usar

- **Direct HID:** feche o software oficial, abra `direct-hid/Abrir-DirectHID-0.2.1.cmd` e clique em **CONECTAR MI_02**.
- **Studio:** abra o software oficial no modo *Ritmo musical > Colorido*, rode `studio/Abrir-K552M-Studio.cmd`, ajuste a paleta e clique em **ATIVAR**.

Detalhes de cada ferramenta estão no `LEIA-ME.txt` da pasta.

## Aviso

Projeto pessoal, sem relação com a Redragon. Use por sua conta e risco.
