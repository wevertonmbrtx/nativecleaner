# Otimizador de RAM (PowerShell)

Este script realiza uma otimização agressiva da memória RAM no Windows, utilizando chamadas nativas da API do Windows (via C# embutido) para liberar recursos não utilizados.

## Funcionalidades

- **Compressão de Working Sets**: Reduz o uso de memória física de processos (não apaga nem interfere em nada).
- **Limpeza de Cache do Sistema**: Invalida o cache do sistema de arquivos.
- **Limpeza da Standby List**: Purga a lista de espera de memória.
- **Verificação de Privilégios**: Solicita elevação para Administrador automaticamente se necessário.
- **Interface Minimalista**: Minimiza a janela do console durante a execução.

## Pré-requisitos

- Windows 10 ou 11.
- PowerShell 5.1 ou superior.
- Privilégios de Administrador.

## Como Usar

**OTIMIZAR RAM**
1. Baixe o arquivo `Otimizar RAM.ps1`.
2. Clique com o botão direito e selecione **"Executar com o PowerShell"**.
   - *Ou execute como Administrador.*

**wrapper**
1. Baixe o arquivo `wrapper.bat`.
2. Clique 2 vezes para executar o script automaticamente
   - *Pode acontecer do seu antivirus(ou o SmartScreen - Windows Defender) bloquear o script*
   - *Se isso acontecer, libere o arquivo no seu anti-vírus e execute novamente*

**Linha de Comando**
Você também pode executar o script diretamente pelo PowerShell:

- **Limpar RAM**:
  ```powershell
  irm bit.ly/wgitncr | iex
  ```

- **Limpar Cache**:
  ```powershell
  irm bit.ly/wgitnca | iex
  ```

- **Limpeza completa (RAM + Cache)**:
  ```powershell
  irm bit.ly/wgitncf | iex
  ```

## Aviso

Este script manipula diretamente a memória do sistema. Embora seguro para uso geral, a limpeza agressiva de cache pode causar uma leve lentidão temporária logo após a execução, enquanto o sistema recarrega dados frequentemente usados. Use o script com cautela. Recomendo salvar e fechar os aplicativos abertos (navegadores, jogos, etc.) antes da execução. No caso do **wrapper**, como ele limpa tudo, além da recomendação anterior, também oriento a verificar os itens na lixeira pois ele também apaga.
