# Entrega contínua: GitHub Actions → Amazon ECR → Amazon EC2

Este documento descreve a pipeline de **Continuous Deployment** (`.github/workflows/deploy.yml`)
e a infraestrutura AWS usada para hospedar a API.

## Fluxo completo

```
Alteração no código → Branch → Pull Request → CI (ruff + pytest + smoke test do container)
→ Merge na main → CI novamente → Build Docker → Push no ECR → Deploy na EC2 → Aplicação atualizada
```

## Arquitetura

```
 Desenvolvedor
     │ git push (branch) + Pull Request
     ▼
 ┌──────────────────────────── GitHub ─────────────────────────────┐
 │  Pull Request  → ci.yml                                         │
 │  merge na main → deploy.yml                                     │
 │       test (ci.yml) ─► build-and-push ─────────► deploy (SSM)   │
 └──────────────────────────┬──────────────────────────┬───────────┘
              OIDC (STS)    │ docker push               │ SSM Run Command
                            ▼                           ▼
              ┌──────────────────────┐  pull  ┌─────────────────────────────────┐
              │     Amazon ECR       │◄───────┤ Amazon EC2 · Amazon Linux 2023  │
              │  devops-python-api   │        │ IAM Role: ECR somente leitura   │
              │  tags: <sha>, latest │        │ contêiner devops-python-api     │
              └──────────────────────┘        │ porta 80 (host) → 8000 (API)    │
                                              └────────────────┬────────────────┘
                                                               │ HTTP 80/TCP
                                                            Usuário
```

## Jobs do `deploy.yml`

Disparado a cada `push` na `main` (merge de Pull Request) ou manualmente.

| Job | Depende de | O que faz |
|---|---|---|
| `test` | — | Reutiliza o `ci.yml` (`workflow_call`): Ruff, pytest com cobertura ≥ 90% e smoke test do container. |
| `build-and-push` | `test` | Assume uma IAM Role via **OIDC**, faz login no ECR, constrói a imagem e publica com as tags `<sha do commit>` e `latest`. |
| `deploy` | `build-and-push` | Assume a mesma role via OIDC e envia um **SSM Run Command** (AWS Systems Manager) para a EC2: `aws ecr get-login-password` → `docker login` → `docker pull <imagem:sha>` → remove o contêiner antigo → `docker run` do novo → `docker ps` para confirmar. Depois testa `GET /version` pela internet. |

**Se os testes falharem, `build-and-push` e `deploy` não são executados** (`needs`).
O `concurrency` impede dois deploys simultâneos.

## Credenciais

Nenhuma credencial está versionada.

| Onde | Nome | Para quê |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | Role assumida pelo GitHub Actions via OIDC (sem access keys) |
| Variable | `EC2_HOST` | IP público (Elastic IP) da EC2 |
| Variable | `EC2_INSTANCE_ID` | ID da instância que recebe o deploy |

A EC2 baixa as imagens com a **IAM Role da instância** (`AmazonEC2ContainerRegistryReadOnly`),
sem nenhuma chave salva no servidor.

### Por que SSM em vez de SSH?

O acesso administrativo para o deploy usa o **AWS Systems Manager**: o agente SSM (já instalado no
Amazon Linux 2023) mantém uma conexão de saída criptografada com a AWS, e a pipeline envia comandos
autenticados por IAM. Assim não há chave SSH para guardar ou vazar, a **porta 22 fica fechada** e cada
deploy fica auditado no histórico do Run Command. A role do GitHub só pode enviar comandos para a
instância com a tag `Name=devops-python-api`.

## Recursos AWS (região `us-east-1`)

Todos são criados pelo script `infra/setup-aws.sh`, executado no AWS CloudShell:

```bash
curl -fsSL https://raw.githubusercontent.com/CaioE-ux/devops-python-api/main/infra/setup-aws.sh | bash
```

| Recurso | Configuração |
|---|---|
| ECR | Repositório **privado** `devops-python-api` |
| Provedor OIDC | `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` |
| Role do GitHub | Confiança: `infra/github-oidc-trust-policy.json` (só a `main` e o environment `production` deste repositório). Permissões: `infra/github-ecr-push-policy.json` e `infra/github-ssm-deploy-policy.json` |
| Role da EC2 | `ec2-ecr-readonly` com `AmazonEC2ContainerRegistryReadOnly` e `AmazonSSMManagedInstanceCore` |
| EC2 | Amazon Linux 2023, `t3.micro`, user data `infra/ec2-user-data.sh` (instala e inicia o Docker) |
| Security Group | Entrada somente 80/TCP (HTTP) |
| Elastic IP | Endereço fixo da instância |

## Como verificar a versão implantada

```bash
curl http://35.174.164.47/version
# {"version":"1.0.0","commit":"<sha do commit da main>"}
```

- `commit` deve ser igual ao último commit da `main` e à tag da imagem mais recente no ECR.
- Na aba **Actions**, o resumo de cada deploy mostra a imagem publicada e a resposta de `/version`.
- No console da AWS: **Systems Manager → Run Command → Command history** mostra a saída de cada deploy, incluindo o `docker ps`.

## Limpeza

Depois da avaliação: encerrar a EC2, liberar o Elastic IP, apagar o repositório do ECR,
as roles, o security group e o provedor OIDC.
