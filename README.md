# Pulso Urbano — Banco de Dados Oracle

**Global Solution 2026/1 · FIAP · ADS 2º ano**  
Disciplina: **Mastering Relational and Non-Relational Database**

---

## O banco como coração do sistema

O Pulso Urbano não é apenas um app bonito — é uma pipeline científica: satélites capturam dados reais do ar de São Paulo, o banco Oracle processa esses dados com lógica PL/SQL própria, e o resultado chega ao celular do usuário em segundos.

Quando a API Java recebe uma requisição de score, ela não calcula no Java: ela chama uma **stored procedure Oracle** (`calcular_score_zona`) que lê a leitura mais recente do satélite, aplica a fórmula, classifica o resultado e persiste — tudo dentro do banco. O trigger `trg_log_score_consulta` registra automaticamente cada operação. Se o score for CRÍTICO, `trg_alerta_critico` dispara um INSERT na tabela do .NET. A API Java apenas orquestra; a inteligência está aqui.

---

## Equipe

| Integrante | RM | Papel |
|------------|-----|-------|
| **Felipe Ferrete** | 562999 | Tech Lead · integrou stored procedures na API Java via `StoredProcedureQuery`; definiu schema unificado e fórmula de score |
| **Clayton Alves** | 562285 | Database · DevOps · **dono desta entrega** — schema Oracle completo, carga de 80+ registros, PL/SQL (blocos, cursores, package, triggers, relatórios), modelagem NoSQL |
| **Guilherme Sola** | 563674 | Mobile · Frontend |
| **Gustavo Bosak** | 566315 | QA · Arquitetura TOGAF |
| **Nikolas Brisola** | 564371 | IoT · ESP32 |

---

## Arquivos

| Arquivo | Propósito |
|---------|-----------|
| `puSCHEMA.sql` | Schema unificado de referência — DDL completo: tabelas, sequences, constraints, triggers, procedures, índices. Ponto de partida para subir o banco do zero. |
| `pulso_urbano_banco_final.sql` | **Entrega FIAP** — contém todas as rubricas: requisitos, DML (≥80 registros), blocos anônimos, cursores, package, relatórios SQL e modelagem NoSQL. Execute APÓS o schema. |

---

## Diagrama de Entidade-Relacionamento

```
USUARIO ──────────────────────────────────────────────────────────┐
  id_usuario (PK) · nome · email (UQ) · hash_senha                │
  faz_exercicio · tem_crianca · tem_problema_resp · role · ativo  │
                                                                   │
ZONA_CIDADE                                                        │
  id_zona (PK) · nome · municipio · lat · lon · ativo             │
       │                                                           │
       │ 1:N                                                       │
       ▼                                                           │
LEITURA_SATELITE ── PK composta                                    │
  (id_zona FK, tipo_dado, dt_captura)                              │
  satelite · valor · unidade · dt_ingestao                         │
       │                                                           │
       │ (scheduler Java lê → chama procedure)                     │
       ▼                                                           │
SCORE_DIARIO ◄─────────────────── RECOMENDACAO ◄──────────────────┘
  id_score (PK)                     id_rec (PK)
  id_zona (FK) · dt_score            id_score (FK) · id_usuario (FK)
  valor_score · classificacao        texto · icone · dt_entrega
  no2_valor · temp_valor             └── 1:1 por score
       │
       │ (trigger AFTER INSERT)
       ▼
LOG_CONSULTA                        ── domínio Java
  id_log (PK) · id_usuario (FK)
  id_zona (FK) · endpoint · dt_consulta

─ ─ ─ ─ ─ ─ ─ ─ ─ domínio .NET ─ ─ ─ ─ ─ ─ ─ ─ ─

ZONA_REFERENCIA_NET                 ALERTA_HISTORICO
  ID_ZONA (PK) · NOME · MUNICIPIO     ID_ALERTA (PK)
        │                             ID_ZONA (FK, Restrict)
        │ 1:N                         NIVEL_ALERTA · SCORE_REGISTRADO
        └─────────────────────────►   NO2_REGISTRADO · DT_ALERTA
                                      CONFIRMADO
```

**8 tabelas no total** — 6 no domínio Java, 2 no domínio .NET — sem FK cruzada entre domínios (cada API mantém sua própria integridade referencial).

---

## Stack

| Componente | Versão/Detalhe |
|------------|----------------|
| Banco | Oracle 19c / 23c Free Edition (`XEPDB1` / `FREEPDB1`) |
| Banco FIAP | `oracle.fiap.com.br:1521/orcl` (schema: `rm562999`) |
| Docker (dev local) | `gvenzl/oracle-xe:21-slim` via Docker Compose do devops |
| PL/SQL | Package + 3 procedures + 3 functions + 3 triggers + 6 blocos anônimos + 4 cursores + 5 relatórios |
| NoSQL | Modelagem MongoDB documentada (coleção `recomendacoes`) |

---

## Fórmula do Score

```sql
-- Aplicada dentro da procedure calcular_score_zona
scoreNo2  := GREATEST(0, 1 - v_no2_ppb  / 50.0);
scoreTemp := GREATEST(0, 1 - GREATEST(0, (v_temp_c - 30) / 20));
v_score   := ROUND((scoreNo2 * 0.60 + scoreTemp * 0.40) * 100, 1);
```

| Faixa | Classificação | Interpretação |
|-------|--------------|---------------|
| ≥ 80  | **BOM** | Ar seguro para todas as atividades |
| ≥ 60  | **MODERADO** | Atenção para grupos sensíveis |
| ≥ 40  | **RUIM** | Reduza atividades ao ar livre |
| < 40  | **CRÍTICO** | Alerta de saúde — API .NET notificada automaticamente |

Limite OMS para NO₂: **25 ppb**. São Paulo pode chegar a 55+ ppb na Zona Leste e Centro.

---

## Objetos PL/SQL

### Package `PKG_PULSO_URBANO`

Encapsula toda a lógica central com constantes definidas:

```sql
PKG_PULSO_URBANO.C_LIMITE_NO2_OMS  -- 25 (ppb)
PKG_PULSO_URBANO.C_PESO_NO2        -- 0.60
PKG_PULSO_URBANO.C_PESO_TEMP       -- 0.40
PKG_PULSO_URBANO.C_TEMP_CONFORTO   -- 30 (°C)
```

### Procedures

| Procedure | Assinatura | O que faz |
|-----------|-----------|-----------|
| `calcular_score_zona` | `(p_zona_id IN NUMBER)` | Lê a leitura mais recente de NO₂ e temperatura para a zona, calcula o score, insere em `score_diario` e faz COMMIT. **Chamada diretamente pelo scheduler Java via `StoredProcedureQuery` do JPA.** |
| `registrar_recomendacao` | `(p_zona_id IN NUMBER, p_usuario_id IN NUMBER)` | Gera recomendação personalizada baseada no score atual e perfil do usuário (faz_exercicio, tem_crianca, tem_problema_resp). |
| `processar_lote_zonas` | `(p_data IN DATE DEFAULT SYSDATE)` | Itera sobre todas as zonas ativas num loop FOR e chama `calcular_score_zona` para cada uma; registra erros por zona em `log_consulta` sem abortar o lote. |

**Exemplo de chamada pelo Java:**
```java
// ScoreService.java
StoredProcedureQuery query = em
    .createStoredProcedureQuery("PKG_PULSO_URBANO.calcular_score_zona")
    .registerStoredProcedureParameter("p_zona_id", Long.class, ParameterMode.IN)
    .setParameter("p_zona_id", zonaId);
query.execute();
```

### Functions

| Function | Assinatura | Retorno |
|----------|-----------|---------|
| `get_classificacao` | `(p_score IN NUMBER) RETURN VARCHAR2` | `'BOM'`, `'MODERADO'`, `'RUIM'` ou `'CRITICO'` |
| `get_texto_recomendacao` | `(p_classificacao IN VARCHAR2, p_faz_exercicio IN NUMBER, p_tem_crianca IN NUMBER, p_tem_problema IN NUMBER) RETURN VARCHAR2` | Texto de recomendação personalizado (até 500 chars) |
| `calcular_media_score_zona` | `(p_zona_id IN NUMBER, p_dias IN NUMBER DEFAULT 7) RETURN NUMBER` | Média de `valor_score` nos últimos N dias para a zona |

**Exemplos:**
```sql
-- Verificar função de classificação
SELECT get_classificacao(90) AS bom,
       get_classificacao(65) AS moderado,
       get_classificacao(45) AS ruim,
       get_classificacao(30) AS critico
FROM DUAL;

-- Média de score dos últimos 30 dias — Centro
SELECT PKG_PULSO_URBANO.calcular_media_score_zona(1, 30) AS media_centro FROM DUAL;
```

### Triggers

| Trigger | Evento | O que faz |
|---------|--------|-----------|
| `trg_valida_score` | `BEFORE INSERT OR UPDATE ON score_diario` | Valida que `valor_score` está entre 0 e 100 (complementa o CHECK constraint); verifica consistência entre valor e classificação (CRITICO só se < 40, etc.). Lança `RAISE_APPLICATION_ERROR` se inválido. |
| `trg_log_score_consulta` | `AFTER INSERT ON score_diario` | Insere automaticamente um registro em `log_consulta` com endpoint `'score/calculado'` e a zona da leitura. Auditoria 100% automática — sem necessidade de código no Java. |
| `trg_alerta_critico` | `AFTER INSERT ON score_diario` quando `classificacao = 'CRITICO'` | Insere na tabela `ALERTA_HISTORICO` (domínio .NET) com nível `'EMERGENCIA'`. Aciona o ciclo de alertas do .NET sem nenhuma lógica extra no Java. |

---

## Blocos Anônimos (6 blocos com exceções)

Todos estão na Seção 4 do `pulso_urbano_banco_final.sql`:

| Bloco | Propósito | Exceção tratada |
|-------|-----------|----------------|
| Bloco 1 | Calcular e exibir score de todas as 5 zonas | `NO_DATA_FOUND` quando zona não tem leitura |
| Bloco 2 | Listar usuários em zonas críticas com cursor FOR | `TOO_MANY_ROWS` se query retornar resultado inesperado |
| Bloco 3 | Processar recomendações em lote com WHILE loop | Exceção genérica com ROLLBACK por zona |
| Bloco 4 | Relatório de tendência — comparar última semana vs. anterior | `VALUE_ERROR` em conversão numérica |
| Bloco 5 | Validação de dados de satélite (range check) | Exceção customizada para valores fora de range |
| Bloco 6 | Simulação de inserção com rollback intencional | Demonstração de tratamento de constraint violation |

---

## Cursores Explícitos (4 cursores)

```sql
-- Cursor 1: Zonas com score crítico nos últimos 30 dias
CURSOR c_zonas_criticas IS
  SELECT z.nome, COUNT(*) AS dias_criticos, AVG(s.valor_score) AS media_score
  FROM score_diario s JOIN zona_cidade z ON s.id_zona = z.id_zona
  WHERE s.classificacao = 'CRITICO'
    AND s.dt_score >= SYSDATE - 30
  GROUP BY z.nome;

-- Cursor 2: Usuários vulneráveis (problema resp. ou criança) em zonas críticas
CURSOR c_usuarios_vulneraveis (p_classificacao VARCHAR2) IS
  SELECT u.nome, u.email, u.tem_problema_resp, u.tem_crianca
  FROM usuario u
  WHERE (u.tem_problema_resp = 1 OR u.tem_crianca = 1)
    AND u.ativo = 1;

-- Cursor 3: Evolução de score — zona por dia (últimos 7 dias)
CURSOR c_evolucao_zona (p_zona_id NUMBER) IS
  SELECT dt_score, valor_score, classificacao
  FROM score_diario
  WHERE id_zona = p_zona_id
    AND dt_score >= SYSDATE - 7
  ORDER BY dt_score;

-- Cursor 4: Ranking de poluição — média NO₂ por zona
CURSOR c_ranking_no2 IS
  SELECT z.nome, AVG(l.valor) AS media_no2
  FROM leitura_satelite l JOIN zona_cidade z ON l.id_zona = z.id_zona
  WHERE l.tipo_dado = 'NO2'
    AND l.dt_captura >= SYSDATE - 30
  GROUP BY z.nome
  ORDER BY media_no2 DESC;
```

---

## Relatórios SQL (5 relatórios com JOIN)

```sql
-- Relatório 1: Score mais recente por zona (visão executiva)
SELECT z.nome AS zona,
       s.valor_score,
       s.classificacao,
       s.no2_valor AS "NO2 (ppb)",
       s.temp_valor AS "Temp (°C)",
       s.dt_score
FROM score_diario s
JOIN zona_cidade z ON s.id_zona = z.id_zona
WHERE s.dt_score = (
  SELECT MAX(s2.dt_score)
  FROM score_diario s2
  WHERE s2.id_zona = s.id_zona
)
ORDER BY s.valor_score;

-- Relatório 2: Usuários vulneráveis em zonas críticas hoje
SELECT u.nome, u.email,
       z.nome AS zona,
       s.valor_score,
       CASE WHEN u.tem_problema_resp = 1 THEN 'Sim' ELSE 'Não' END AS respiratorio,
       CASE WHEN u.tem_crianca = 1       THEN 'Sim' ELSE 'Não' END AS tem_crianca
FROM usuario u
CROSS JOIN zona_cidade z
JOIN score_diario s ON s.id_zona = z.id_zona
  AND s.dt_score = TRUNC(SYSDATE)
WHERE s.classificacao = 'CRITICO'
  AND (u.tem_problema_resp = 1 OR u.tem_crianca = 1)
  AND u.ativo = 1
ORDER BY s.valor_score, u.nome;

-- Relatório 3: Ranking de zonas mais poluídas (últimos 30 dias)
SELECT z.nome AS zona,
       ROUND(AVG(l.valor), 2) AS media_no2_ppb,
       MAX(l.valor) AS pico_no2_ppb,
       COUNT(DISTINCT l.dt_captura) AS dias_com_leitura,
       CASE WHEN AVG(l.valor) > 40 THEN 'ALTA'
            WHEN AVG(l.valor) > 25 THEN 'MODERADA'
            ELSE 'BAIXA' END AS exposicao
FROM leitura_satelite l
JOIN zona_cidade z ON l.id_zona = z.id_zona
WHERE l.tipo_dado = 'NO2'
  AND l.dt_captura >= SYSDATE - 30
GROUP BY z.nome
ORDER BY media_no2_ppb DESC;

-- Relatório 4: Evolução mensal — comparar semana atual vs. anterior
SELECT z.nome AS zona,
       ROUND(AVG(CASE WHEN s.dt_score >= SYSDATE - 7
                      THEN s.valor_score END), 1) AS media_semana_atual,
       ROUND(AVG(CASE WHEN s.dt_score BETWEEN SYSDATE - 14 AND SYSDATE - 7
                      THEN s.valor_score END), 1) AS media_semana_anterior,
       ROUND(
         AVG(CASE WHEN s.dt_score >= SYSDATE - 7 THEN s.valor_score END) -
         AVG(CASE WHEN s.dt_score BETWEEN SYSDATE - 14 AND SYSDATE - 7
                  THEN s.valor_score END),
       1) AS delta
FROM score_diario s
JOIN zona_cidade z ON s.id_zona = z.id_zona
GROUP BY z.nome
ORDER BY delta DESC;

-- Relatório 5: Alertas gerados (.NET) por zona e nível nos últimos 30 dias
SELECT zn.NOME AS zona,
       ah.NIVEL_ALERTA,
       COUNT(*) AS total_alertas,
       ROUND(AVG(ah.SCORE_REGISTRADO), 1) AS score_medio,
       MIN(ah.DT_ALERTA) AS primeiro_alerta,
       MAX(ah.DT_ALERTA) AS ultimo_alerta
FROM ALERTA_HISTORICO ah
JOIN ZONA_REFERENCIA_NET zn ON ah.ID_ZONA = zn.ID_ZONA
WHERE ah.DT_ALERTA >= SYSDATE - 30
GROUP BY zn.NOME, ah.NIVEL_ALERTA
ORDER BY zn.NOME, ah.NIVEL_ALERTA;
```

---

## Modelagem NoSQL

Além do modelo relacional, documentamos como os dados de recomendação seriam armazenados em MongoDB (NoSQL documental):

```json
// Coleção: recomendacoes
// Índice: { "usuarioId": 1, "dtEntrega": -1 }
{
  "_id": { "$oid": "665f1a2b3c4d5e6f7a8b9c0d" },
  "usuarioId": 42,
  "zonaNome": "Centro",
  "score": 34.2,
  "classificacao": "CRITICO",
  "dtEntrega": { "$date": "2026-06-07T08:00:00Z" },
  "perfil": {
    "fazExercicio": true,
    "temCrianca": false,
    "temProblemaRespiratorio": true
  },
  "recomendacao": {
    "titulo": "Qualidade do ar crítica",
    "texto": "Mantenha janelas fechadas. Evite qualquer atividade ao ar livre. Com asma ou bronquite, use a medicação preventiva.",
    "icone": "alert-circle",
    "prioridade": 1
  },
  "fontes": ["SENTINEL_5P", "ECOSTRESS"],
  "leitura": {
    "no2_ppb": 52.1,
    "temp_superfice_c": 41.3
  },
  "lida": false
}
```

**Por que MongoDB aqui?** O documento `recomendacao` é lido por completo a cada requisição do app mobile (nunca por campo isolado), evolui com o perfil do usuário (schema flexível), e tem acesso pattern `find({ usuarioId, dtEntrega: { $gte: ... } })` — padrão ideal para document store com índice composto.

---

## Como Executar

### Pré-requisitos

- Oracle Database (FIAP: `oracle.fiap.com.br:1521/orcl` ou local via Docker — veja `devops/docker-compose.yml`)
- SQL*Plus ou qualquer cliente Oracle (DBeaver, SQL Developer)

### Passo a passo

```bash
# 1. Conectar ao banco (usuário Oracle do schema)
sqlplus rm562999/senha@//oracle.fiap.com.br:1521/orcl

# OU em desenvolvimento local (Oracle via Docker):
sqlplus system/oracle@//localhost:1521/XEPDB1
```

```sql
-- 2. Criar schema completo (tabelas, sequences, constraints, triggers, procedures, package)
@puSCHEMA.sql

-- 3. Carregar dados de teste e executar entrega FIAP (blocos anônimos, cursores, relatórios)
@pulso_urbano_banco_final.sql
```

### Verificação após execução

```sql
-- Contagem total de registros (deve ser >= 80)
SELECT 'usuario'              AS tabela, COUNT(*) AS registros FROM usuario         UNION ALL
SELECT 'zona_cidade',                    COUNT(*) FROM zona_cidade                  UNION ALL
SELECT 'leitura_satelite',               COUNT(*) FROM leitura_satelite             UNION ALL
SELECT 'score_diario',                   COUNT(*) FROM score_diario                 UNION ALL
SELECT 'recomendacao',                   COUNT(*) FROM recomendacao                 UNION ALL
SELECT 'log_consulta',                   COUNT(*) FROM log_consulta                 UNION ALL
SELECT 'ZONA_REFERENCIA_NET',            COUNT(*) FROM ZONA_REFERENCIA_NET          UNION ALL
SELECT 'ALERTA_HISTORICO',               COUNT(*) FROM ALERTA_HISTORICO;

-- Testar functions
SELECT get_classificacao(90) AS bom,
       get_classificacao(65) AS moderado,
       get_classificacao(45) AS ruim,
       get_classificacao(30) AS critico
FROM DUAL;

-- Testar media de score (Zone 1 = Centro)
SELECT PKG_PULSO_URBANO.calcular_media_score_zona(1, 30) AS media_30dias FROM DUAL;

-- Verificar trigger de auditoria — score_diario → log_consulta automático
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (1, TRUNC(SYSDATE)+1, 75.0, 'MODERADO', 28.0, 33.0);
COMMIT;
SELECT * FROM log_consulta WHERE endpoint = 'score/calculado' ORDER BY dt_consulta DESC;

-- Verificar trigger de alerta crítico
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (2, TRUNC(SYSDATE)+1, 25.0, 'CRITICO', 55.0, 42.0);
COMMIT;
SELECT * FROM ALERTA_HISTORICO ORDER BY DT_ALERTA DESC;
```

---

## Como a API Java Usa Este Banco

```
App Mobile
    ↓ GET /api/v1/score/current (JWT)
Java API (Spring Boot)
    ↓ StoredProcedureQuery
    ↓ PKG_PULSO_URBANO.calcular_score_zona(p_zona_id)
Oracle
    ├── lê leitura_satelite (NO₂ e Temp mais recentes)
    ├── aplica fórmula de score
    ├── INSERT em score_diario
    │   ├── trg_valida_score (BEFORE) — valida range
    │   ├── trg_log_score_consulta (AFTER) → log_consulta
    │   └── trg_alerta_critico (AFTER, se CRITICO) → ALERTA_HISTORICO
    └── COMMIT
Java API
    ↓ SELECT da leitura mais recente (JPA @Entity)
App Mobile ← JSON com score, classificação, _links HATEOAS
```

As entidades JPA (`ScoreDiario`, `ZonaCidade`, `LeituraSatelite`) mapeiam diretamente as tabelas Oracle com `@Table(name = "score_diario")` e `@Column(name = "valor_score")`.

---

## Zonas Monitoradas

| ID | Zona | Lat | Lon | Perfil |
|----|------|-----|-----|--------|
| 1 | Centro | -23.5505 | -46.6333 | Alta densidade industrial, NO₂ elevado |
| 2 | Zona Leste | -23.5474 | -46.4767 | Maior concentração industrial, picos de NO₂ |
| 3 | Zona Sul | -23.6821 | -46.6242 | Moderado, parques amenizam temperatura |
| 4 | Zona Norte | -23.4891 | -46.6262 | Misto residencial/industrial |
| 5 | Zona Oeste | -23.5607 | -46.7182 | Menor NO₂, temperatura mais amena |

---

## Rubrica Coberta

### Mastering Relational and Non-Relational Database — Checklist

| Requisito | Status | Evidência |
|-----------|--------|-----------|
| Mínimo 6 tabelas relacionais | ✅ | 8 tabelas: usuario, zona_cidade, leitura_satelite, score_diario, recomendacao, log_consulta, ZONA_REFERENCIA_NET, ALERTA_HISTORICO |
| Mínimo 80 registros de teste | ✅ | 25 usuários + 28 leituras satélite + 15 scores + 10 recomendações + 12 logs + 5 zonas ref + 40 alertas = 135+ registros |
| 6 blocos anônimos com exceções | ✅ | Seção 4 do `pulso_urbano_banco_final.sql` — 1 exceção por bloco mínimo |
| 4 estruturas condicionais IF/ELSIF/ELSE | ✅ | Na procedure `calcular_score_zona`, function `get_classificacao`, trigger `trg_valida_score`, bloco de validação de range |
| 4 estruturas de repetição (LOOP, WHILE, FOR) | ✅ | `processar_lote_zonas` (FOR), bloco de lote (WHILE), cursor FOR loop, blocos de relatório (basic LOOP) |
| 4 cursores explícitos | ✅ | c_zonas_criticas, c_usuarios_vulneraveis, c_evolucao_zona, c_ranking_no2 |
| Package com procedures, functions, triggers | ✅ | `PKG_PULSO_URBANO`: 3 procedures + 3 functions + 3 triggers encapsulados |
| 5 relatórios com JOIN | ✅ | 5 relatórios documentados acima — todos com 2+ tabelas |
| Modelagem NoSQL | ✅ | Coleção MongoDB `recomendacoes` com documento completo e justificativa |
| DER e modelo relacional | ✅ | Diagrama ASCII neste README + DDL comentado no SQL |

### Apresentação Presencial — O que demonstrar

| Momento | O que fazer |
|---------|-------------|
| Contexto | Explicar o fluxo: satélite → Oracle → API Java → app |
| DER | Apontar as 8 tabelas, os domínios Java/.NET, as FKs |
| Carga de dados | `SELECT COUNT(*) FROM...` mostrando 80+ registros |
| Blocos PL/SQL | Executar Bloco 1 (score de todas as zonas) ao vivo |
| Package | `EXECUTE PKG_PULSO_URBANO.processar_lote_zonas()` |
| Triggers | INSERT em `score_diario` → mostrar log automático gerado |
| Functions | `SELECT get_classificacao(35) FROM DUAL` |
| NoSQL | Mostrar documento JSON e explicar escolha do MongoDB |
| Relatórios | Executar Relatório 2 (usuários vulneráveis em zonas críticas) |

---

## Perguntas da Banca

**"Por que usar stored procedure em vez de calcular no Java?"**
> A lógica de score é um invariante de negócio — não pode ser diferente entre a API Java, a API .NET ou qualquer futuro serviço. Centralizar no banco garante consistência e evita duplicação. Além disso, a procedure acessa os dados sem round-trip de rede.

**"O que o trigger faz exatamente?"**
> `trg_valida_score` valida integridade antes do INSERT; `trg_log_score_consulta` registra auditoria automaticamente pós-INSERT; `trg_alerta_critico` aciona o ciclo .NET sem nenhuma lógica extra no Java — o banco detecta CRÍTICO e age.

**"Como a FK cruzada entre domínios Java e .NET funciona?"**
> Não existe FK cruzada. Cada API tem seu schema isolado. O trigger `trg_alerta_critico` insere em `ALERTA_HISTORICO` (tabela .NET) como efeito colateral controlado — design intencional para independência.

**"Qual a diferença entre `puSCHEMA.sql` e `pulso_urbano_banco_final.sql`?"**
> `puSCHEMA.sql` é o schema de produção — o mesmo que as APIs usam. `pulso_urbano_banco_final.sql` é a entrega FIAP — executa APÓS o schema, adicionando dados de teste e demonstrações das rubricas (blocos anônimos, cursores, relatórios, modelagem NoSQL).

---

## Links

| Recurso | URL |
|---------|-----|
| Java API (usa este banco) | `https://hearty-adaptation-production-6de3.up.railway.app/swagger-ui.html` |
| .NET API (tabelas ALERTA_HISTORICO) | `http://20.12.204.186:5000/swagger` |
| Repositório geral | _preencher após publicação_ |
| Vídeo demonstração banco | _[YouTube — preencher após gravação]_ |
