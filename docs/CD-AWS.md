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
 │       test (ci.yml) ─► build-and-push ─────────► deploy         │
 └──────────────────────────┬──────────────────────────┬───────────┘
              OIDC (STS)    │ docker push               │ SSH (22/TCP)
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
| `deploy` | `build-and-push` | Por SSH: `aws ecr get-login-password` → `docker login` → `docker pull <imagem:sha>` → remove o contêiner antigo → `docker run` do novo → `docker ps` para confirmar → `curl /version` pela internet. |

**Se os testes falharem, `build-and-push` e `deploy` não são executados** (`needs`).
O `concurrency` impede dois deploys simultâneos.

## Credenciais

Nenhuma credencial está versionada.

| Onde | Nome | Para quê |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | Role assumida pelo GitHub Actions via OIDC (sem access keys) |
| Secret | `EC2_SSH_KEY` | Chave privada SSH usada no deploy |
| Variable | `EC2_HOST` | IP público (Elastic IP) da EC2 |
| Variable | `EC2_USER` | `ec2-user` |

A EC2 baixa as imagens com a **IAM Role da instância** (`AmazonEC2ContainerRegistryReadOnly`),
sem nenhuma chave salva no servidor.

## Recursos AWS (região `us-east-1`)

| Recurso | Configuração |
|---|---|
| ECR | Repositório **privado** `devops-python-api` |
| Provedor OIDC | `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` |
| Role do GitHub | Confiança: `infra/github-oidc-trust-policy.json` (só a `main` deste repositório). Permissão: `infra/github-ecr-push-policy.json` |
| Role da EC2 | `ec2-ecr-readonly` com `AmazonEC2ContainerRegistryReadOnly` |
| EC2 | Amazon Linux 2023, `t3.micro`, user data `infra/ec2-user-data.sh` (instala e inicia o Docker) |
| Security Group | Entrada 22/TCP (SSH) e 80/TCP (HTTP) |
| Elastic IP | Endereço fixo da instância |

## Como verificar a versão implantada

```bash
curl http://<IP-DA-EC2>/version
# {"version":"1.0.0","commit":"<sha do commit da main>"}
```

- `commit` deve ser igual ao último commit da `main` e à tag da imagem mais recente no ECR.
- Na aba **Actions**, o resumo de cada deploy mostra a imagem publicada e a resposta de `/version`.
- Na EC2, `docker ps` mostra o contêiner rodando com a imagem `...:<sha>`.

## Limpeza

Depois da avaliação: encerrar a EC2, liberar o Elastic IP, apagar o repositório do ECR,
as roles e o provedor OIDC.
