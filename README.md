# Network and Disk Performance Test Pod

Este repositório contém uma imagem utilitária para executar testes básicos de rede e disco a partir de um pod no OpenShift, sem rodar container como root.

O objetivo principal é apoiar investigações de performance em migrações, especialmente cenários como VMware para OpenShift Virtualization via MTV, separando hipóteses de gargalo em:

- rede entre OpenShift e VMware;
- acesso TCP aos endpoints VMware/vCenter/ESXi;
- MTU e caminho de rede;
- throughput de rede com `iperf3`;
- performance de escrita/leitura no PVC destino;
- comportamento do storage usado pelas VMs, como ODF/Ceph RBD.

## Entrar no Pod

```bash
oc exec -it -n <namespace> <pod-name> -- bash
```

Exemplo:

```bash
oc exec -it -n net-test net-disk-performance-test -- bash
```

## Testes de Rede Basicos

### DNS

```bash
dig <fqdn-vcenter>
dig <fqdn-esxi>
```

Exemplo:

```bash
dig vcsrs00-vc.infra.demo.redhat.com
dig esxi-02002.infra.demo.redhat.com
```

### Rota usada pelo pod

```bash
ip route get <ip-destino>
```

Exemplo:

```bash
ip route get 169.60.6.106
```

### Ver MTU das interfaces do pod

```bash
ip link
```

Em muitos clusters OpenShift com overlay, a interface do pod pode usar MTU menor que 1500, por exemplo 1400. Nesse caso, o maior payload ICMP sem fragmentacao sera:

```text
MTU - 28 bytes
```

Para MTU 1400:

```text
1400 - 28 = 1372
```

### Teste de MTU sem fragmentacao

```bash
ping -M do -s <payload> <destino>
```

Para MTU 1400:

```bash
ping -M do -s 1372 <destino>
ping -M do -s 1373 <destino>
```

Resultado esperado:

- `1372` deve funcionar;
- `1373` deve falhar localmente com `message too long, mtu=1400`.

Exemplo:

```bash
ping -M do -s 1372 esxi-02002.infra.demo.redhat.com
```

## Testes de Porta TCP

Para VMware/vCenter/ESXi, as portas mais importantes para a investigacao costumam ser:

- `443`: API HTTPS/vCenter/ESXi;
- `902`: trafego NFC/NBD usado em operacoes de disco VMware/VDDK.

### Testar vCenter

```bash
nc -vz <fqdn-vcenter> 443
nc -vz <fqdn-vcenter> 902
```

Exemplo:

```bash
nc -vz vcsrs00-vc.infra.demo.redhat.com 443
nc -vz vcsrs00-vc.infra.demo.redhat.com 902
```

Observacao: a porta `902` pode nao responder no vCenter, dependendo da arquitetura. O teste mais importante costuma ser contra os ESXi hosts.

### Testar ESXi

```bash
nc -vz <fqdn-esxi> 443
nc -vz <fqdn-esxi> 902
```

Exemplo:

```bash
nc -vz esxi-02002.infra.demo.redhat.com 443
nc -vz esxi-02002.infra.demo.redhat.com 902
```

Interpretacao:

- `Connected`: porta acessivel.
- `Connection refused`: o host respondeu, mas nao ha servico escutando ou a conexao foi recusada.
- `TIMEOUT`: possivel firewall, ACL, rota, filtragem ou destino incorreto.

### Testar varios ESXi

```bash
for h in \
  esxi-02001.infra.demo.redhat.com \
  esxi-02002.infra.demo.redhat.com \
  esxi-02003.infra.demo.redhat.com
do
  echo "== $h =="
  dig +short "$h"
  nc -vz -w 3 "$h" 443
  nc -vz -w 3 "$h" 902
done
```

## Testes HTTP/TLS

### Tempo de conexao no vCenter ou ESXi

```bash
curl -k -o /dev/null -s -w \
'connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s speed=%{speed_download}\n' \
https://<fqdn-ou-ip>/
```

Exemplo:

```bash
curl -k -o /dev/null -s -w \
'connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s speed=%{speed_download}\n' \
https://vcsrs00-vc.infra.demo.redhat.com/
```

Executar varias vezes:

```bash
for i in $(seq 1 10); do
  curl -k -o /dev/null -s -w "$i connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s speed=%{speed_download}\n" \
  https://<fqdn-ou-ip>/
done
```

Este teste nao mede throughput de disco, mas ajuda a identificar lentidao ou instabilidade de conexao TCP/TLS.

## Teste de Throughput com iperf3

Para medir throughput real, e necessario ter `iperf3` rodando nos dois lados. Se nao for possivel rodar `iperf3` no ESXi, crie uma VM temporaria no VMware, na mesma rede ou caminho usado pelo OpenShift para acessar o ambiente VMware.

### Na VM do VMware

```bash
iperf3 -s
```

### Dentro do pod no OpenShift

Teste OpenShift para VMware:

```bash
iperf3 -c <ip-da-vm-vmware> -P 4 -t 60
```

Teste reverso, VMware para OpenShift:

```bash
iperf3 -c <ip-da-vm-vmware> -P 4 -t 60 -R
```

Com mais streams:

```bash
iperf3 -c <ip-da-vm-vmware> -P 8 -t 60
iperf3 -c <ip-da-vm-vmware> -P 8 -t 60 -R
```

Interpretacao rapida:

- perto de `940 Mbits/sec`: caminho provavelmente limitado a 1 Gb;
- varios `Gbits/sec`: caminho 10/25 Gb ou superior provavelmente esta funcional;
- muitos retransmits TCP: possivel perda, congestionamento, MTU/MSS ou firewall;
- resultado reverso muito pior: possivel assimetria de rede.

## Testes de Disco em PVC

Estes testes medem o PVC montado no pod, por exemplo em `/data`. Eles ajudam a validar se o storage destino do OpenShift esta entregando throughput compativel.

> Importante: se a VM usa PVC com `volumeMode: Block`, o ideal e tambem testar um PVC block. Os testes abaixo usam arquivo em filesystem montado em `/data`.

### Escrita sequencial

```bash
fio --name=seq-write \
  --filename=/data/testfile \
  --size=30G \
  --rw=write \
  --bs=1M \
  --ioengine=libaio \
  --iodepth=16 \
  --direct=1 \
  --numjobs=1 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

### Leitura sequencial

```bash
fio --name=seq-read \
  --filename=/data/testfile \
  --size=30G \
  --rw=read \
  --bs=1M \
  --ioengine=libaio \
  --iodepth=16 \
  --direct=1 \
  --numjobs=1 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

### Leitura e escrita randomica

```bash
fio --name=randrw \
  --filename=/data/testfile-randrw \
  --size=20G \
  --rw=randrw \
  --rwmixread=70 \
  --bs=4k \
  --ioengine=libaio \
  --iodepth=32 \
  --direct=1 \
  --numjobs=4 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

## Teste em PVC Block

Se quiser testar um PVC com `volumeMode: Block`, monte o volume como device no pod, por exemplo em `/dev/testblock`, e rode `fio` diretamente no device.

Exemplo de comando:

```bash
fio --name=block-write \
  --filename=/dev/testblock \
  --size=20G \
  --rw=write \
  --bs=1M \
  --ioengine=libaio \
  --iodepth=16 \
  --direct=1 \
  --numjobs=1 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

Leitura:

```bash
fio --name=block-read \
  --filename=/dev/testblock \
  --size=20G \
  --rw=read \
  --bs=1M \
  --ioengine=libaio \
  --iodepth=16 \
  --direct=1 \
  --numjobs=1 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

Cuidado: testes de escrita em block device podem sobrescrever dados. Use somente PVCs descartaveis criados para teste.

## Como Relacionar com MTV

Durante uma migracao VMware para OpenShift Virtualization via MTV, separe as fases:

```text
PreflightInspection
DiskTransfer
Cutover
ImageConversion
VirtualMachineCreation
```

Para acompanhar:

```bash
watch -n 30 'oc get migration -n openshift-mtv <migration-name> -o yaml | egrep -i "name:|phase:|started:|completed:|reason:|Precopy|DiskTransfer|Cutover|ImageConversion|VirtualMachineCreation"'
```

Durante `DiskTransfer`, observar:

```bash
oc get pods -A -o wide | egrep -i '<vm-name>|importer|cdi|forklift|transfer|populator'
oc get dv,pvc -n <namespace-da-vm>
oc describe dv <dv-name> -n <namespace-da-vm>
oc describe pvc <pvc-name> -n <namespace-da-vm>
```

Durante `ImageConversion`, observar:

```bash
oc get pods -A -o wide | egrep -i '<vm-name>|conversion|virt-v2v'
oc logs -n <namespace-da-vm> <conversion-pod> --all-containers -f
oc describe pod -n <namespace-da-vm> <conversion-pod>
oc adm top pod -n <namespace-da-vm> <conversion-pod>
```

## Interpretacao dos Resultados

Use os testes para separar as hipoteses:

| Evidencia | Suspeita principal |
| --- | --- |
| `iperf3` baixo nos dois sentidos | rede, caminho, firewall, MTU, uplink |
| `iperf3` bom, PVC lento no `fio` | storage destino, ODF/Ceph, StorageClass, PVC |
| `iperf3` bom, PVC bom, `DiskTransfer` lento | VMware, VDDK/NBD/NFC, datastore read, ESXi/vmkernel, snapshots |
| `DiskTransfer` bom, `ImageConversion` lento | `virt-v2v`, CPU/memoria do pod, leitura/escrita no PVC, Windows conversion |
| porta `902` inacessivel para ESXi | caminho VDDK/NBD/NFC pode estar bloqueado ou usando rota alternativa |

## Referencia de Comparacao

Para calcular throughput efetivo de uma migracao:

```text
throughput = tamanho_do_disco / duracao
```

Exemplo:

```text
250 GB em 4h38m ~= 15 MB/s
```

Se o PVC entrega 200 MB/s em `fio`, mas o `DiskTransfer` entrega 15 MB/s, a causa provavelmente nao e apenas a escrita bruta no PVC. Investigue VMware/VDDK/NBD/NFC, datastore e caminho de rede do ESXi.

