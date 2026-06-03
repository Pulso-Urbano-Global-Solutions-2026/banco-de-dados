# Pulso Urbano — Banco de Dados

**Global Solution 2026/1 · FIAP ADS**  
Disciplina: Mastering Relational and Non-Relational Database

---

## Equipe

| Integrante | RM | Papel | Responsabilidades |
|------------|-----|-------|-------------------|
| **Felipe Ferrete** | 562999 | Tech Lead · Java · .NET | Arquitetura geral; todos os endpoints Java (score, recomendação, mapa, usuário, histórico); integração com Copernicus API (OAuth2) e NASA Earthdata para ingestão orbital real; engine de score e engine de recomendação; Spring Security + JWT; Swagger/OpenAPI; API .NET de histórico de alertas (CRUD + Oracle Migrations); deploy em nuvem (Railway/Fly.io); README master |
| **Clayton Alves** | 562285 | Database · DevOps | Schema Oracle (DDL, FKs, sequences, triggers, procedures); carga de dados de teste (≥80 registros); PL/SQL completo (blocos anônimos, cursores, relatórios, modelagem NoSQL); Dockerfile + docker-compose; deploy de containers em nuvem; diagrama de arquitetura macro |
| **Guilherme Sola** | 563674 | Mobile · Frontend | React Native — 5 telas: Home (score + classificação), Mapa (camadas NO₂/temperatura), Histórico (gráfico 7 dias), Perfil (cadastro + preferências), Detalhes (explicação educacional); CRUD completo via Axios; tratamento de erros e loading states; vídeo de demonstração |
| **Gustavo Bosak** | 566315 | QA · Arquitetura | TOGAF/ArchiMate (visões de negócio, sistema e tecnologia); identificação de stakeholders e drivers; validação funcional das telas mobile; testes de endpoints da API; documentação de bugs; casos de teste para apresentação presencial |
| **Nikolas Brisola** | 564371 | IoT · ESP32 | ESP32 no Wokwi: DHT22 + MQ135, LEDs de alerta, display LCD 16x2; Wi-Fi + MQTT publicando para broker HiveMQ Cloud; backend Java consome tópico e armazena em `leitura_iot`; 3 endpoints JSON documentados; vídeo do protótipo |

---

## Sobre o projeto

O Pulso Urbano transforma dados orbitais de satélites públicos em um **score de saúde ambiental (0–100)** por zona da cidade de São Paulo, personalizado pelo perfil de saúde do usuário.

Dados do **Sentinel-5P (ESA)** para NO₂ e do **ECOSTRESS (NASA)** para temperatura superficial são ingeridos por um scheduler Java e armazenados neste banco Oracle. A cada ciclo, o score é calculado, classificado e recomendações personalizadas são geradas. Alertas críticos são gerenciados por uma API .NET separada.

---

## Arquivos

| Arquivo | Propósito |
|---------|-----------|
| `puSCHEMA.sql` | Schema unificado de referência (Java + .NET). Usado para subir o banco do zero. Em produção cada API usa seu próprio `db.init`. |
| `pulso_urbano_banco_final.sql` | **Entrega FIAP** — contém todas as rubricas da disciplina: requisitos, DDL, DML (≥80 registros), PL/SQL completo, relatórios SQL e modelagem NoSQL. |

---

## Banco de dados

**Oracle 19c / 23c Free Edition** (`XEPDB1` / `FREEPDB1`)

### Divisão de domínios

O schema é compartilhado entre dois backends sem FK cruzada entre eles.

```
Java API  (Spring Boot 3.2 · porta 8080)
  Tabelas   : usuario, zona_cidade, leitura_satelite,
              score_diario, recomendacao, log_consulta
  Sequences : seq_usuario, seq_zona, seq_score,
              seq_recomendacao, seq_log  (allocationSize=1)

.NET API  (ASP.NET Core 8 · porta 5000)
  Tabelas   : ZONA_REFERENCIA_NET, ALERTA_HISTORICO
  Sequences : SEQ_ZONA_REFERENCIA, SEQ_ALERTA_HISTORICO  (HiLo · INCREMENT BY 10)
```

`ZONA_REFERENCIA_NET` espelha `ZONA_CIDADE` via seed determinístico (562999), sem FK — cada API mantém sua própria integridade referencial.

### Algoritmo de score

```
scoreNo2  = max(0, 1 − no2_ppb / 50.0)
scoreTemp = max(0, 1 − max(0, (tempC − 30) / 20))
score     = round((scoreNo2 × 0.60 + scoreTemp × 0.40) × 100, 1)
```

| Faixa | Classificação |
|-------|--------------|
| ≥ 80 | BOM |
| ≥ 60 | MODERADO |
| ≥ 40 | RUIM |
| < 40 | CRITICO |

Limite OMS para NO₂: **25 ppb**. Temperatura de conforto: **30 °C**.

### Objetos PL/SQL

| Objeto | Tipo | Descrição |
|--------|------|-----------|
| `calcular_score_zona(p_zona_id)` | Procedure | Lê a leitura mais recente, insere em `score_diario` e faz commit. Chamada pelo scheduler Java via `StoredProcedureQuery`. |
| `registrar_recomendacao(...)` | Procedure | Insere recomendação personalizada. Chamada pelo `RecomendacaoService` Java. |
| `processar_lote_zonas` | Procedure | Processa todas as zonas ativas em loop; registra erros em `log_consulta`. |
| `get_classificacao(p_score)` | Function | Retorna string de classificação para um valor de score. |
| `get_texto_recomendacao(...)` | Function | Gera texto de recomendação com base no score e perfil do usuário. |
| `calcular_media_score_zona(p_zona_id, p_dias)` | Function | Média de score de uma zona nos últimos N dias (padrão 7). |
| `PKG_PULSO_URBANO` | Package | Encapsula tudo acima com constantes (`C_LIMITE_NO2_OMS`, `C_PESO_NO2`, etc.). |
| `trg_valida_score` | Trigger | BEFORE INSERT/UPDATE em `score_diario` — valida range e consistência score × classificação. |
| `trg_log_score_consulta` | Trigger | AFTER INSERT em `score_diario` — grava auditoria em `log_consulta` automaticamente. |
| `trg_alerta_critico` | Trigger | AFTER INSERT em `score_diario` quando `CRITICO` — insere em `ALERTA_HISTORICO`. |

---

## Como executar

```bash
# 1. Criar o schema (sequences, tabelas, triggers, procedures, seed)
sqlplus user/password@//localhost:1521/XEPDB1 @puSCHEMA.sql

# 2. Carregar dados de teste e objetos adicionais da entrega FIAP
sqlplus user/password@//localhost:1521/XEPDB1 @pulso_urbano_banco_final.sql
```

Para resetar em desenvolvimento, descomentar o bloco `BEGIN ... END;` de drops no topo de `puSCHEMA.sql`.

### Verificação

```sql
-- Contagem de registros por tabela (esperado: total >= 80)
SELECT 'usuario'             AS tabela, COUNT(*) AS registros FROM usuario         UNION ALL
SELECT 'zona_cidade',        COUNT(*) FROM zona_cidade                             UNION ALL
SELECT 'leitura_satelite',   COUNT(*) FROM leitura_satelite                        UNION ALL
SELECT 'score_diario',       COUNT(*) FROM score_diario                            UNION ALL
SELECT 'recomendacao',       COUNT(*) FROM recomendacao                            UNION ALL
SELECT 'log_consulta',       COUNT(*) FROM log_consulta                            UNION ALL
SELECT 'ZONA_REFERENCIA_NET',COUNT(*) FROM ZONA_REFERENCIA_NET                     UNION ALL
SELECT 'ALERTA_HISTORICO',   COUNT(*) FROM ALERTA_HISTORICO;

-- Teste das functions
SELECT get_classificacao(90) AS bom, get_classificacao(30) AS critico FROM DUAL;
SELECT PKG_PULSO_URBANO.calcular_media_score_zona(1, 30) AS media_centro FROM DUAL;
```

---

## Zonas monitoradas

| ID | Zona | Lat | Lon |
|----|------|-----|-----|
| 1 | Centro | -23.5505 | -46.6333 |
| 2 | Zona Leste | -23.5474 | -46.4767 |
| 3 | Zona Sul | -23.6821 | -46.6242 |
| 4 | Zona Norte | -23.4891 | -46.6262 |
| 5 | Zona Oeste | -23.5607 | -46.7182 |
