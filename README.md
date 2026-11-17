# API Python para demonstrar DevOps

Repositório didático para apresentar, em uma única aplicação, quatro ideias que se conectam:

1. uma API HTTP escrita em Python;
2. integração contínua com GitHub Actions;
3. execução reproduzível com Docker;
4. entrega contínua na AWS: imagem publicada no Amazon ECR e implantada automaticamente em uma instância Amazon EC2.

O projeto utiliza FastAPI, pytest, Ruff, GitHub Actions, Docker, Amazon ECR, Amazon EC2 e AWS IAM (OIDC e Instance Profile). Os dados ficam em memória para manter a atenção da aula no fluxo DevOps, sem introduzir banco de dados.

## O que os estudantes devem observar

- O código funciona localmente e no runner do GitHub.
- A mesma suíte de testes é executada pelo desenvolvedor e pelo pipeline.
- O Dockerfile descreve o ambiente necessário para executar a API.
- O pipeline só testa o container depois que qualidade e testes foram aprovados.
- Logs, cobertura e relatórios funcionam como evidências, não apenas como mensagens coloridas.

## Estrutura do repositório

```text
.
├── .github/workflows/
│   ├── ci.yml                 # integração contínua (Pull Requests)
│   └── deploy.yml             # entrega contínua: ECR + EC2 (push na main)
├── app/
│   ├── __init__.py
│   └── main.py                # API FastAPI
├── docs/
│   ├── API.md
│   ├── CD-AWS.md              # pipeline de deploy e arquitetura AWS
│   ├── DOCKER.md
│   ├── GITHUB-ACTIONS.md
│   └── ROTEIRO-AULA.md
├── infra/                     # script de provisionamento AWS, user data e políticas IAM
├── tests/test_api.py          # testes automatizados
├── .dockerignore
├── .python-version
├── compose.yaml
├── Dockerfile
├── pyproject.toml             # configuração de pytest, cobertura e Ruff
├── requirements.txt           # dependências de execução
└── requirements-dev.txt       # dependências de desenvolvimento e CI
```

## 1. Executar localmente

Pré-requisitos: Git e Python 3.13.

### Linux e macOS

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements-dev.txt
uvicorn app.main:app --reload
```

### Windows PowerShell

```powershell
py -3.13 -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install --requirement requirements-dev.txt
uvicorn app.main:app --reload
```

Acesse:

- API: <http://localhost:8000>
- documentação Swagger: <http://localhost:8000/docs>
- verificação de saúde: <http://localhost:8000/health>

## 2. Experimentar a API

```bash
curl http://localhost:8000/health

curl -X POST http://localhost:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Estudar integração contínua"}'

curl http://localhost:8000/tasks

curl -X PATCH http://localhost:8000/tasks/1/done
```

Endpoints:

| Método | Caminho | Objetivo | Resposta esperada |
|---|---|---|---|
| GET | `/` | Apresentar a API | `200` |
| GET | `/health` | Informar saúde e versão | `200` |
| GET | `/version` | Versão e commit implantado | `200` |
| GET | `/tasks` | Listar tarefas | `200` |
| POST | `/tasks` | Criar uma tarefa | `201` |
| PATCH | `/tasks/{id}/done` | Concluir uma tarefa | `200` ou `404` |

Veja a explicação do código em [docs/API.md](docs/API.md).

## 3. Executar as verificações locais

```bash
ruff check .
ruff format --check .
pytest --cov=app --cov-report=term-missing
```

Esses comandos são deliberadamente iguais aos usados no GitHub Actions. Se uma verificação falhar localmente, ela também deverá falhar no pipeline.

Para aplicar a formatação automaticamente:

```bash
ruff format .
```

## 4. Publicar no GitHub e acionar a CI

O diretório já é inicializado como repositório Git local. Crie um repositório vazio no GitHub e execute:

```bash
git remote add origin https://github.com/SEU-USUARIO/devops-python-api.git
git push -u origin main
```

O arquivo `.github/workflows/ci.yml` dispara o pipeline em três situações:

- `pull_request` aberto ou atualizado com destino à `main`;
- execução manual pela aba **Actions**;
- chamada pelo `deploy.yml` (`workflow_call`), que roda o CI antes de cada deploy.

Etapas: checkout → Python (versão de `.python-version`) → dependências → `ruff check` →
`ruff format --check` → pytest com cobertura mínima de 90% → relatórios como artefato →
build e smoke test do container. O resultado (✅/❌) aparece no resumo da execução e no check do Pull Request.

Na aba **Actions**, abra a execução e faça a leitura nesta ordem:

1. workflow;
2. job;
3. primeiro step que falhou;
4. comando e mensagem que explicam a falha.

A explicação detalhada do YAML está em [docs/GITHUB-ACTIONS.md](docs/GITHUB-ACTIONS.md).

## 5. Executar com Docker

```bash
docker build -t devops-python-api:v1 .
docker run --rm -p 8000:8000 --name devops-python-api devops-python-api:v1
```

Em outro terminal:

```bash
curl http://localhost:8000/health
docker ps
docker logs devops-python-api
```

Com Docker Compose:

```bash
docker compose up --build
docker compose down
```

Veja a leitura detalhada do Dockerfile em [docs/DOCKER.md](docs/DOCKER.md).

## 6. Entrega contínua na AWS (CD)

A cada merge na `main`, o workflow `.github/workflows/deploy.yml`:

1. executa o CI completo (se falhar, nada é publicado);
2. autentica na AWS via **OIDC**, sem access keys guardadas no GitHub;
3. faz login no **Amazon ECR**, constrói a imagem e publica com a tag do **SHA do commit** (e `latest`);
4. envia um **SSM Run Command** (AWS Systems Manager) para a **EC2**, que autentica o Docker no ECR usando a **IAM Role** da instância (sem chave SSH e sem porta 22 aberta);
5. baixa a imagem do commit, substitui o contêiner anterior e inicia a nova versão (porta 80 → 8000);
6. confirma com `docker ps` e com `GET /version` pela internet.

Nenhum comando manual é executado na EC2 a cada alteração.

A infraestrutura (ECR, OIDC, roles, security group, EC2 e Elastic IP) é criada pelo script
`infra/setup-aws.sh`. Arquitetura, recursos AWS, secrets e verificação: [docs/CD-AWS.md](docs/CD-AWS.md).

### API publicada

- URL: <http://35.174.164.47>
- Documentação Swagger: <http://35.174.164.47/docs>
- Versão implantada: <http://35.174.164.47/version>

```bash
curl http://35.174.164.47/version
# {"version":"1.0.0","commit":"<sha do último commit da main>"}
```

### Evidências

| Evidência | Arquivo |
|---|---|
| CI executado no Pull Request | `docs/evidencias/01-ci-pr.png` |
| Imagem no ECR com a tag do commit | `docs/evidencias/02-ecr.png` |
| Pipeline de deploy concluída | `docs/evidencias/03-deploy.png` |
| Contêiner em execução na EC2 | `docs/evidencias/04-docker-ps.png` |
| API v1 no navegador | `docs/evidencias/05-api-v1.png` |
| API v2 após o deploy automático | `docs/evidencias/06-api-v2.png` |

Pull Requests:

- PR 1: implementação da esteira CI/CD (`feature/ci-cd-ec2`)
- PR 2: nova versão da aplicação (deploy automático)

## Falhas intencionais para demonstrar

### Falha de teste

Em `app/main.py`, altere temporariamente a versão do health check para `2.0.0`. O teste espera `1.0.0`, então o pytest e o pipeline devem falhar.

### Falha de qualidade

Adicione um import não utilizado no início de `app/main.py`:

```python
import os
```

O step `ruff check .` localizará o problema.

### Falha de rede no container

No `Dockerfile`, troque `--host 0.0.0.0` por `--host 127.0.0.1`. O processo iniciará, mas o serviço não ficará acessível pela porta publicada no host.

## Próximos desafios

- Adicionar um endpoint `DELETE /tasks/{id}` e seus testes.
- Executar os testes em uma matriz com Python 3.12, 3.13 e 3.14.
- Publicar a imagem em um registry somente após a aprovação dos testes.
- Substituir o armazenamento em memória por um banco de dados.

## Referências oficiais

- [GitHub Actions: criar e testar Python](https://docs.github.com/pt/actions/tutorials/build-and-test-code/building-and-testing-python)
- [actions/checkout](https://github.com/actions/checkout)
- [actions/setup-python](https://github.com/actions/setup-python)
- [actions/upload-artifact](https://github.com/actions/upload-artifact)
- [FastAPI](https://fastapi.tiangolo.com/)
- [Docker para Python](https://docs.docker.com/language/python/)
