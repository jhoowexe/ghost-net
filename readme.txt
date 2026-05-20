# Ghost-Net 🕶️

Script automatizado para **anonimato no Kali Linux**, incluindo:
- Limpeza de rastros e arquivos temporários
- MAC spoofing (endereço de rede aleatório)
- Conexão VPN com killswitch (iptables)
- Integração com Tor (SOCKS5)
- Menu interativo para fácil utilização

---

## 🚀 Instalação

Clone o repositório e torne o script executável:
```bash
git clone https://github.com/SEU_USUARIO/ghost-net.git
cd ghost-net
chmod +x ghost_net.sh
```

Ou baixe direto:
```bash
curl -L https://raw.githubusercontent.com/SEU_USUARIO/ghost-net/main/ghost_net.sh -o ghost_net.sh
chmod +x ghost_net.sh
```

---

## 🔧 Dependências
Instale os pacotes necessários:
```bash
sudo apt update
sudo apt install -y openvpn tor macchanger iptables curl network-manager torsocks
```

---

## 🖥️ Uso
Execute o script com permissões de root:
```bash
sudo ./ghost_net.sh
```

Será exibido um menu interativo:
```
==============================
  G H O S T - N E T   M E N U
==============================
[1] Anonimato total (VPN + Tor + MAC + Killswitch)
[2] Limpeza de rastros (simples)
[3] Limpeza agressiva (inclui journals/logs)
[4] Somente Tor (forçado via firewall)
[5] Somente VPN (com killswitch)
[6] Status do ambiente
[7] Reverter tudo (parar Tor/VPN, restaurar MAC, iptables)
[0] Sair
```

### Exemplo: rodar com anonimato total
Escolha a opção **1** → o script irá:
- Limpar arquivos temporários
- Alterar MAC da interface escolhida
- Conectar VPN (`.ovpn`)
- Ativar killswitch (bloqueio total de tráfego fora da VPN)
- Iniciar o Tor e redirecionar tráfego
- Mostrar status final

### Exemplo: apenas limpeza
Opção **2** → remove históricos, caches e temporários. 

### Exemplo: status
Opção **6** → mostra IP público, status da VPN/Tor, iptables ativos e MAC atual.

---

## ⚡ Instalação global (opcional)
Para usar o comando `ghost-net` em qualquer lugar:
```bash
sudo mv ghost_net.sh /usr/local/bin/ghost-net
sudo chmod +x /usr/local/bin/ghost-net
```

Agora é só rodar:
```bash
sudo ghost-net
```

---

## ⚠️ Aviso
Este script é para fins educacionais e de privacidade. Não garante anonimato absoluto e não deve ser usado para atividades ilegais. Combine sempre com boas práticas de segurança digital.

