-- ============================================================
-- PULSO URBANO — BANCO DE DADOS FINAL
-- Global Solution 2026/1 · FIAP · Turmas de Fevereiro
-- Disciplina: Mastering Relational and Non-Relational Database
-- Felipe Ferrete · RM 562999
-- ============================================================
-- IMPORTANTE: Este arquivo foi gerado sobre o schema unificado
-- real (puSCHEMA.sql v1.0). Os nomes de tabelas, colunas e
-- sequences são idênticos aos usados pelas APIs Java e .NET.
-- Execute APÓS o schema unificado já estar criado no banco.
-- ============================================================

-- ============================================================
-- SEÇÃO 1 — LEVANTAMENTO DE REQUISITOS
-- ============================================================

-- PROBLEMA ABORDADO:
-- A população de São Paulo é exposta diariamente a níveis elevados
-- de poluição atmosférica (NO₂) e ilhas de calor urbano sem acesso
-- fácil a informações consolidadas sobre qualidade ambiental do
-- seu bairro. Dados orbitais de satélites como Sentinel-5P (ESA) e
-- ECOSTRESS (NASA) existem e são públicos, mas complexos demais para
-- o cidadão comum. O Pulso Urbano resolve isso: transforma dados
-- orbitais em score 0-100 de saúde ambiental por zona da cidade,
-- personalizado pelo perfil de saúde do usuário.

-- OBJETIVOS DA SOLUÇÃO:
-- 1. Ingerir leituras de NO₂ e temperatura superficial via satélite
--    por zona monitorada de São Paulo
-- 2. Calcular diariamente um score ambiental (0-100) por zona
-- 3. Classificar o score em BOM / MODERADO / RUIM / CRITICO
-- 4. Gerar recomendações personalizadas com base no perfil do usuário
-- 5. Emitir alertas automáticos para zonas críticas (.NET API)
-- 6. Manter auditoria completa de todas as consultas (LOG_CONSULTA)

-- REGRAS DE NEGÓCIO:
-- RN01: scoreNo2  = max(0, 1 - no2_ppb / 50.0)
--       scoreTemp = max(0, 1 - max(0, (tempC - 30) / 20))
--       score     = round((scoreNo2 * 0.60 + scoreTemp * 0.40) * 100, 1)
-- RN02: score >= 80 → BOM
-- RN03: score >= 60 e < 80 → MODERADO
-- RN04: score >= 40 e < 60 → RUIM
-- RN05: score < 40 → CRITICO
-- RN06: Limite OMS para NO₂ é 25 ppb — leituras acima exigem alerta
-- RN07: Temperatura de conforto é 30°C — acima disso penaliza o score
-- RN08: Usuários com problema respiratório recebem recomendações
--       mais restritivas
-- RN09: Usuários com crianças recebem avisos específicos sobre
--       exposição infantil
-- RN10: Cada zona pode ter apenas um score por data (dt_score)
-- RN11: valor_score deve estar entre 0 e 100 (CHECK constraint)
-- RN12: Todo INSERT em score_diario gera log automático (trigger)
-- RN13: Alerts gerenciados pelo .NET API via ALERTA_HISTORICO

-- PROCESSOS AUTOMATIZADOS:
-- PA01: trg_valida_score valida score e classificação (BEFORE INSERT/UPDATE)
-- PA02: trg_log_score_consulta registra auditoria (AFTER INSERT)
-- PA03: Procedure calcular_score_zona processa leituras por zona
-- PA04: Procedure registrar_recomendacao gera recomendação por perfil
-- PA05: Package PKG_PULSO_URBANO encapsula lógica central

-- INDICADORES CALCULADOS:
-- IC01: Score diário por zona (0-100)
-- IC02: Média de score por zona nos últimos N dias
-- IC03: Ranking de zonas mais poluídas (média NO₂)
-- IC04: Quantidade de alertas por zona e período
-- IC05: Usuários vulneráveis em zonas críticas

-- ============================================================
-- SEÇÃO 2 — DDL
-- (Compatível com schema unificado real — sem recriar estrutura
--  já existente; DROP/CREATE apenas em tabelas de apoio novas)
-- ============================================================

-- As 8 tabelas principais já foram criadas pelo puSCHEMA.sql:
-- USUARIO, ZONA_CIDADE, LEITURA_SATELITE, SCORE_DIARIO,
-- RECOMENDACAO, LOG_CONSULTA, ZONA_REFERENCIA_NET, ALERTA_HISTORICO
--
-- As sequences existentes são:
-- seq_usuario, seq_zona, seq_score, seq_recomendacao, seq_log (Java)
-- SEQ_ZONA_REFERENCIA, SEQ_ALERTA_HISTORICO (HiLo .NET)
--
-- Abaixo: confirmação do DDL real para documentação da entrega.

/*
  -- USUARIO (domínio Java)
  CREATE TABLE usuario (
    id_usuario        NUMBER CONSTRAINT pk_usuario PRIMARY KEY
                      DEFAULT seq_usuario.NEXTVAL,
    nome              VARCHAR2(150)  NOT NULL,
    email             VARCHAR2(200)  NOT NULL CONSTRAINT uq_usuario_email UNIQUE,
    hash_senha        VARCHAR2(255)  NOT NULL,
    faz_exercicio     NUMBER(1)      DEFAULT 0 NOT NULL,
    tem_crianca       NUMBER(1)      DEFAULT 0 NOT NULL,
    tem_problema_resp NUMBER(1)      DEFAULT 0 NOT NULL,
    role              VARCHAR2(20)   DEFAULT 'USER' NOT NULL,
    ativo             NUMBER(1)      DEFAULT 1 NOT NULL,
    dt_criacao        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT chk_faz_exerc   CHECK (faz_exercicio    IN (0,1)),
    CONSTRAINT chk_tem_crianca CHECK (tem_crianca       IN (0,1)),
    CONSTRAINT chk_tem_resp    CHECK (tem_problema_resp IN (0,1)),
    CONSTRAINT chk_role        CHECK (role              IN ('USER','ADMIN')),
    CONSTRAINT chk_ativo_usr   CHECK (ativo             IN (0,1))
  );

  -- ZONA_CIDADE (domínio Java)
  CREATE TABLE zona_cidade (
    id_zona   NUMBER        CONSTRAINT pk_zona PRIMARY KEY
              DEFAULT seq_zona.NEXTVAL,
    nome      VARCHAR2(100) NOT NULL,
    municipio VARCHAR2(100) DEFAULT 'São Paulo',
    lat       NUMBER(9,6),
    lon       NUMBER(9,6),
    ativo     NUMBER(1)     DEFAULT 1 NOT NULL,
    CONSTRAINT chk_ativo_zona CHECK (ativo IN (0,1)),
    CONSTRAINT chk_lat        CHECK (lat   BETWEEN -90  AND  90),
    CONSTRAINT chk_lon        CHECK (lon   BETWEEN -180 AND 180)
  );

  -- LEITURA_SATELITE (domínio Java) — PK COMPOSTA
  CREATE TABLE leitura_satelite (
    id_zona     NUMBER       NOT NULL,
    tipo_dado   VARCHAR2(30) NOT NULL,
    dt_captura  TIMESTAMP    NOT NULL,
    satelite    VARCHAR2(50),
    valor       NUMBER(10,4) NOT NULL,
    unidade     VARCHAR2(20),
    dt_ingestao TIMESTAMP    DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_leitura PRIMARY KEY (id_zona, tipo_dado, dt_captura),
    CONSTRAINT fk_leitura_zona FOREIGN KEY (id_zona) REFERENCES zona_cidade(id_zona),
    CONSTRAINT chk_tipo_dado CHECK (tipo_dado IN ('NO2','TEMP_SUPERFICIE','UV')),
    CONSTRAINT chk_satelite  CHECK (satelite  IN ('SENTINEL_5P','ECOSTRESS','OMI','OPEN_METEO'))
  );

  -- SCORE_DIARIO (domínio Java)
  CREATE TABLE score_diario (
    id_score      NUMBER       CONSTRAINT pk_score PRIMARY KEY
                  DEFAULT seq_score.NEXTVAL,
    id_zona       NUMBER       NOT NULL,
    dt_score      DATE         NOT NULL,
    valor_score   NUMBER(5,2)  NOT NULL,
    classificacao VARCHAR2(15) NOT NULL,
    no2_valor     NUMBER(8,4),
    temp_valor    NUMBER(6,2),
    dt_criacao    TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_score_zona FOREIGN KEY (id_zona) REFERENCES zona_cidade(id_zona),
    CONSTRAINT chk_score_val CHECK (valor_score BETWEEN 0 AND 100),
    CONSTRAINT chk_classif   CHECK (classificacao IN ('BOM','MODERADO','RUIM','CRITICO'))
  );

  -- RECOMENDACAO (domínio Java)
  CREATE TABLE recomendacao (
    id_rec      NUMBER         CONSTRAINT pk_recomendacao PRIMARY KEY
                DEFAULT seq_recomendacao.NEXTVAL,
    id_score    NUMBER         NOT NULL,
    id_usuario  NUMBER         NOT NULL,
    texto       VARCHAR2(1000) NOT NULL,
    icone       VARCHAR2(30),
    dt_entrega  TIMESTAMP      DEFAULT SYSTIMESTAMP,
    dt_criacao  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_rec_score   FOREIGN KEY (id_score)   REFERENCES score_diario(id_score),
    CONSTRAINT fk_rec_usuario FOREIGN KEY (id_usuario) REFERENCES usuario(id_usuario)
  );

  -- LOG_CONSULTA (domínio Java)
  CREATE TABLE log_consulta (
    id_log      NUMBER        CONSTRAINT pk_log PRIMARY KEY
                DEFAULT seq_log.NEXTVAL,
    id_usuario  NUMBER,
    id_zona     NUMBER,
    endpoint    VARCHAR2(200),
    ip_origem   VARCHAR2(45),
    dt_consulta TIMESTAMP     DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_log_usuario FOREIGN KEY (id_usuario) REFERENCES usuario(id_usuario),
    CONSTRAINT fk_log_zona    FOREIGN KEY (id_zona)    REFERENCES zona_cidade(id_zona)
  );

  -- ZONA_REFERENCIA_NET (domínio .NET)
  CREATE TABLE ZONA_REFERENCIA_NET (
    ID_ZONA   NUMBER(10)     NOT NULL CONSTRAINT PK_ZONA_REFERENCIA_NET PRIMARY KEY,
    NOME      NVARCHAR2(100) NOT NULL,
    MUNICIPIO NVARCHAR2(100) NOT NULL
  );

  -- ALERTA_HISTORICO (domínio .NET)
  CREATE TABLE ALERTA_HISTORICO (
    ID_ALERTA          NUMBER(10)      NOT NULL CONSTRAINT PK_ALERTA_HISTORICO PRIMARY KEY,
    ID_ZONA            NUMBER(10)      NOT NULL,
    NIVEL_ALERTA       NVARCHAR2(15)   NOT NULL,
    SCORE_REGISTRADO   NUMBER(5,2)     NOT NULL,
    NO2_REGISTRADO     NUMBER(8,4)     NOT NULL,
    TEXTO_RECOMENDACAO NVARCHAR2(1000),
    DT_ALERTA          DATE            NOT NULL,
    CONFIRMADO         NUMBER(1)       NOT NULL,
    CONSTRAINT FK_ALERTA_HISTORICO_ZONA FOREIGN KEY (ID_ZONA)
      REFERENCES ZONA_REFERENCIA_NET(ID_ZONA),
    CONSTRAINT chk_nivel_alerta CHECK (
      NIVEL_ALERTA IN ('ATENCAO','ALERTA','EMERGENCIA')
    )
  );
*/

-- ============================================================
-- SEÇÃO 3 — DML (INSERT DE DADOS DE TESTE)
-- Total: >= 80 registros
-- IDs de zona usam os 5 seeds do schema real (1-5)
-- ============================================================

-- ---- 3.1 USUARIOS (25 registros) ----
-- Seed admin e demo já existem no schema; inserindo usuários adicionais.
-- Usa hash fictício de mesma força (BCrypt strength=12) para testes.
INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Mariana Souza Ferreira','mariana.souza@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Carlos Eduardo Motta','carlos.motta@hotmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Ana Paula Rodrigues','ana.rodrigues@outlook.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Roberto Lima Neto','roberto.lima@yahoo.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Fernanda Costa Alves','fernanda.costa@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Diego Henrique Pinto','diego.pinto@uol.com.br',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Patricia Mendes Xavier','patricia.mendes@terra.com.br',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 1, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Thiago Vieira Santos','thiago.vieira@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Luciana Barbosa Freitas','luciana.barbosa@outlook.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Marcos Antonio Gomes','marcos.gomes@hotmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Juliana Castro Ramos','juliana.castro@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Eduardo Nascimento Leal','eduardo.nascimento@yahoo.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Beatriz Oliveira Dias','beatriz.oliveira@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Rafael Carvalho Teixeira','rafael.carvalho@outlook.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Camila Andrade Moreira','camila.andrade@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 1, 'USER');

-- Usuários adicionais (margem de segurança sobre o mínimo de 80 registros)
INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Gustavo Almeida Rocha','gustavo.almeida@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Helena Martins Cunha','helena.martins@outlook.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Igor Fernandes Brito','igor.fernandes@yahoo.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Larissa Pereira Nunes','larissa.pereira@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 1, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Bruno Tavares Lopes','bruno.tavares@hotmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Sabrina Ribeiro Campos','sabrina.ribeiro@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Vinicius Cardoso Reis','vinicius.cardoso@uol.com.br',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 0, 1, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Tatiane Lima Moraes','tatiane.lima@outlook.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('André Monteiro Pires','andre.monteiro@gmail.com',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 1, 1, 0, 'USER');

INSERT INTO usuario (nome, email, hash_senha, faz_exercicio, tem_crianca, tem_problema_resp, role)
VALUES ('Bianca Azevedo Pinto','bianca.azevedo@terra.com.br',
        '$2a$12$QxRlJ1nKpT8vWsHmZdE3oOcB9yXiN5fP4gDkM2tU7wVaL6s0eYhAI', 0, 0, 1, 'USER');

-- ---- 3.2 LEITURAS_SATELITE (28 registros) ----
-- tipo_dado: NO2 | TEMP_SUPERFICIE (conforme CHECK real)
-- satelite: SENTINEL_5P | ECOSTRESS
-- Zona 1 = Centro, 2 = Zona Leste, 3 = Zona Sul, 4 = Zona Norte, 5 = Zona Oeste

-- Centro (id_zona=1) — alta poluição esperada
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'NO2',           CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'SENTINEL_5P', 42.5, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'ECOSTRESS',   36.8, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'NO2',           CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'SENTINEL_5P', 55.2, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'ECOSTRESS',   39.1, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'NO2',           CAST(TRUNC(SYSDATE)-15 AS TIMESTAMP), 'SENTINEL_5P', 38.7, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (1, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-15 AS TIMESTAMP), 'ECOSTRESS',  34.2, 'celsius');

-- Zona Leste (id_zona=2) — industrial
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (2, 'NO2',           CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'SENTINEL_5P', 48.9, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (2, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'ECOSTRESS',   38.2, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (2, 'NO2',           CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'SENTINEL_5P', 52.1, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (2, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'ECOSTRESS',   41.3, 'celsius');

-- Zona Sul (id_zona=3) — moderado
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (3, 'NO2',           CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'SENTINEL_5P', 28.4, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (3, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'ECOSTRESS',   32.9, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (3, 'NO2',           CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'SENTINEL_5P', 22.1, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (3, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-8 AS TIMESTAMP), 'ECOSTRESS',   30.5, 'celsius');

-- Zona Norte (id_zona=4) — boa qualidade
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (4, 'NO2',           CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'SENTINEL_5P', 14.8, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (4, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'ECOSTRESS',   27.1, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (4, 'NO2',           CAST(TRUNC(SYSDATE)-5 AS TIMESTAMP), 'SENTINEL_5P', 19.3, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (4, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-5 AS TIMESTAMP), 'ECOSTRESS',   28.6, 'celsius');

-- Zona Oeste (id_zona=5) — variado
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'NO2',           CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'SENTINEL_5P', 22.3, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'ECOSTRESS',   31.4, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'NO2',           CAST(TRUNC(SYSDATE)-3 AS TIMESTAMP), 'SENTINEL_5P', 33.6, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-3 AS TIMESTAMP), 'ECOSTRESS',   34.1, 'celsius');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'NO2',           CAST(TRUNC(SYSDATE)-10 AS TIMESTAMP), 'SENTINEL_5P', 10.2, 'ppb');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE)-10 AS TIMESTAMP), 'ECOSTRESS',  26.3, 'celsius');
-- UV extra para Zona Norte
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (4, 'UV', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'OMI', 8.5, 'index');
INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
VALUES (5, 'UV', CAST(TRUNC(SYSDATE)-1 AS TIMESTAMP), 'OMI', 6.2, 'index');

-- ---- 3.3 SCORE_DIARIO (12 registros — cobrir BOM/MODERADO/RUIM/CRITICO) ----
-- Coluna: valor_score, no2_valor, temp_valor (conforme schema real)
-- score = (1-NO2/50)*60 + (1-max(0,(TEMP-30)/20))*40
-- Centro: (1-42.5/50)*60 + (1-(36.8-30)/20)*40 = 9+26.4 = 35.4 CRITICO
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (1, TRUNC(SYSDATE)-1, 35.4, 'CRITICO', 42.5, 36.8);

-- Zona Leste: (1-48.9/50)*60 + (1-(38.2-30)/20)*40 = 1.3+23.6 = 24.9 CRITICO
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (2, TRUNC(SYSDATE)-1, 24.9, 'CRITICO', 48.9, 38.2);

-- Zona Sul: (1-28.4/50)*60 + (1-(32.9-30)/20)*40 = 25.9+34.2 = 60.1 MODERADO
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (3, TRUNC(SYSDATE)-1, 60.1, 'MODERADO', 28.4, 32.9);

-- Zona Norte: (1-14.8/50)*60 + (1-0)*40 = 42.2+40 = 82.2 BOM
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (4, TRUNC(SYSDATE)-1, 82.2, 'BOM', 14.8, 27.1);

-- Zona Oeste: (1-22.3/50)*60 + (1-(31.4-30)/20)*40 = 33.2+37.2 = 70.4 MODERADO
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (5, TRUNC(SYSDATE)-1, 70.4, 'MODERADO', 22.3, 31.4);

-- Histórico Centro (8 dias atrás): pior ainda
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (1, TRUNC(SYSDATE)-8, 8.3, 'CRITICO', 55.2, 39.1);

-- Histórico Zona Leste (8 dias)
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (2, TRUNC(SYSDATE)-8, 14.1, 'CRITICO', 52.1, 41.3);

-- Histórico Zona Sul (8 dias) — mais limpo
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (3, TRUNC(SYSDATE)-8, 72.3, 'MODERADO', 22.1, 30.5);

-- Histórico Zona Norte (5 dias) — BOM
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (4, TRUNC(SYSDATE)-5, 78.4, 'MODERADO', 19.3, 28.6);

-- Zona Oeste 3 dias: RUIM
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (5, TRUNC(SYSDATE)-3, 49.2, 'RUIM', 33.6, 34.1);

-- Zona Oeste 10 dias: BOM
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (5, TRUNC(SYSDATE)-10, 87.8, 'BOM', 10.2, 26.3);

-- Centro 15 dias: RUIM (melhora visível)
INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
VALUES (1, TRUNC(SYSDATE)-15, 44.6, 'RUIM', 38.7, 34.2);

-- ---- 3.4 RECOMENDACOES (12 registros) ----
-- Busca os id_score inseridos acima. Usa subquery para pegar os IDs certos.
INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Qualidade do ar CRITICA no Centro. Evite sair de casa. Use máscara N95 se necessário.',
    'alert-red'
FROM score_diario s, usuario u
WHERE s.id_zona=1 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='mariana.souza@gmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'ALERTA CRÍTICO: Crianças e portadores de asma NÃO devem sair. Janelas fechadas.',
    'alert-red'
FROM score_diario s, usuario u
WHERE s.id_zona=1 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='ana.rodrigues@outlook.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar CRITICO na Zona Leste. Evite atividades externas. Mantenha ambientes ventilados artificialmente.',
    'alert-red'
FROM score_diario s, usuario u
WHERE s.id_zona=2 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='carlos.motta@hotmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar MODERADO na Zona Sul. Rotina normal, mas evite exercícios intensos no horário de pico.',
    'info-yellow'
FROM score_diario s, usuario u
WHERE s.id_zona=3 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='fernanda.costa@gmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar MODERADO — Zona Sul. Crianças podem praticar atividades externas com monitoramento.',
    'info-yellow'
FROM score_diario s, usuario u
WHERE s.id_zona=3 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='patricia.mendes@terra.com.br' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Excelente qualidade do ar na Zona Norte! Score 82.2. Ótimo dia para corrida matinal.',
    'check-green'
FROM score_diario s, usuario u
WHERE s.id_zona=4 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='thiago.vieira@gmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar BOM na Zona Norte! Ótima oportunidade para atividades com crianças ao ar livre.',
    'check-green'
FROM score_diario s, usuario u
WHERE s.id_zona=4 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='marcos.gomes@hotmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar MODERADO na Zona Oeste. Score 70.4. Tudo bem para rotina normal.',
    'info-yellow'
FROM score_diario s, usuario u
WHERE s.id_zona=5 AND s.dt_score=TRUNC(SYSDATE)-1
  AND u.email='juliana.castro@gmail.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Portador de problema respiratório: ar RUIM na Zona Oeste há 3 dias. Evite exposição prolongada.',
    'warning-orange'
FROM score_diario s, usuario u
WHERE s.id_zona=5 AND s.dt_score=TRUNC(SYSDATE)-3
  AND u.email='roberto.lima@yahoo.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar RUIM na Zona Oeste. Exercícios ao ar livre não recomendados hoje.',
    'warning-orange'
FROM score_diario s, usuario u
WHERE s.id_zona=5 AND s.dt_score=TRUNC(SYSDATE)-3
  AND u.email='diego.pinto@uol.com.br' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'CRITICO no Centro há 8 dias. Episódio prolongado. Procure atendimento médico se sentir sintomas.',
    'alert-red'
FROM score_diario s, usuario u
WHERE s.id_zona=1 AND s.dt_score=TRUNC(SYSDATE)-8
  AND u.email='luciana.barbosa@outlook.com' AND ROWNUM=1;

INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
SELECT s.id_score, u.id_usuario,
    'Ar BOM na Zona Oeste há 10 dias! Score 87.8. Aproveite para exercícios.',
    'check-green'
FROM score_diario s, usuario u
WHERE s.id_zona=5 AND s.dt_score=TRUNC(SYSDATE)-10
  AND u.email='beatriz.oliveira@gmail.com' AND ROWNUM=1;

-- ---- 3.5 LOG_CONSULTA (8 registros) ----
INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (1, 'SCHEDULER/calcular_score_zona', '10.0.0.1');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (2, 'SCHEDULER/calcular_score_zona', '10.0.0.1');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (3, 'SCHEDULER/calcular_score_zona', '10.0.0.1');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (4, 'SCHEDULER/calcular_score_zona', '10.0.0.1');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (5, 'SCHEDULER/calcular_score_zona', '10.0.0.1');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (1, '/api/scores/zona/1', '200.150.100.55');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (4, '/api/scores/zona/4', '200.150.100.72');

INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
VALUES (2, '/api/alertas/zona/2', '10.0.0.2');

-- ---- 3.6 ALERTA_HISTORICO (8 registros — domínio .NET) ----
-- nivel: ATENCAO | ALERTA | EMERGENCIA (conforme CHECK real)
INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 1, 'EMERGENCIA', 35.4, 42.5,
    'Emergência ambiental no Centro — NO₂ crítico. Restrição de atividades externas.',
    TRUNC(SYSDATE)-1, 0);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 2, 'EMERGENCIA', 24.9, 48.9,
    'Emergência ambiental na Zona Leste — NO₂ acima de 48 ppb.',
    TRUNC(SYSDATE)-1, 0);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 1, 'EMERGENCIA', 8.3, 55.2,
    'Episódio crítico prolongado no Centro. Segundo evento em 8 dias.',
    TRUNC(SYSDATE)-8, 1);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 2, 'ALERTA', 14.1, 52.1,
    'Alerta na Zona Leste — NO₂ acima de 50 ppb por segundo dia consecutivo.',
    TRUNC(SYSDATE)-8, 1);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 5, 'ATENCAO', 49.2, 33.6,
    'Atenção na Zona Oeste — qualidade do ar deteriorando.',
    TRUNC(SYSDATE)-3, 1);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 3, 'ATENCAO', 60.1, 28.4,
    'Atenção na Zona Sul — NO₂ próximo ao limite OMS.',
    TRUNC(SYSDATE)-1, 0);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 1, 'ALERTA', 44.6, 38.7,
    'Alerta histórico no Centro — tendência de piora detectada.',
    TRUNC(SYSDATE)-15, 1);

INSERT INTO ALERTA_HISTORICO (ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
    NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
VALUES (SEQ_ALERTA_HISTORICO.NEXTVAL, 2, 'EMERGENCIA', 24.9, 48.9,
    'Confirmação .NET: Zona Leste em emergência ambiental contínua.',
    TRUNC(SYSDATE)-1, 0);

COMMIT;

-- ============================================================
-- SEÇÃO 4 — PROGRAMAÇÃO PL/SQL
-- ============================================================

-- ============================================================
-- 4.1 — BLOCOS ANÔNIMOS (6 blocos, cada um com exceção)
-- ============================================================

-- BLOCO 1: Calcular score de uma zona e exibir resultado
DECLARE
    v_zona_id       NUMBER := 1;
    v_no2           NUMBER;
    v_temp          NUMBER;
    v_score         NUMBER;
    v_classificacao VARCHAR2(15);
    v_nome_zona     VARCHAR2(100);
    e_sem_leitura   EXCEPTION;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 1: Cálculo de Score por Zona ===');

    SELECT nome INTO v_nome_zona
    FROM zona_cidade WHERE id_zona = v_zona_id;

    SELECT valor INTO v_no2
    FROM leitura_satelite
    WHERE id_zona = v_zona_id AND tipo_dado = 'NO2'
    ORDER BY dt_captura DESC
    FETCH FIRST 1 ROWS ONLY;

    SELECT valor INTO v_temp
    FROM leitura_satelite
    WHERE id_zona = v_zona_id AND tipo_dado = 'TEMP_SUPERFICIE'
    ORDER BY dt_captura DESC
    FETCH FIRST 1 ROWS ONLY;

    IF v_no2 IS NULL OR v_temp IS NULL THEN
        RAISE e_sem_leitura;
    END IF;

    -- Algoritmo exato: scoreNo2 = max(0, 1 - no2/50), scoreTemp = max(0, 1 - max(0,(temp-30)/20))
    v_score := ROUND(
        (GREATEST(0, 1 - v_no2/50) * 0.60 +
         GREATEST(0, 1 - GREATEST(0, (v_temp - 30)/20)) * 0.40) * 100,
    1);

    IF v_score >= 80 THEN v_classificacao := 'BOM';
    ELSIF v_score >= 60 THEN v_classificacao := 'MODERADO';
    ELSIF v_score >= 40 THEN v_classificacao := 'RUIM';
    ELSE v_classificacao := 'CRITICO'; END IF;

    DBMS_OUTPUT.PUT_LINE('Zona: ' || v_nome_zona);
    DBMS_OUTPUT.PUT_LINE('NO₂: ' || v_no2 || ' ppb | Temp: ' || v_temp || '°C');
    DBMS_OUTPUT.PUT_LINE('Score calculado: ' || v_score);
    DBMS_OUTPUT.PUT_LINE('Classificação: ' || v_classificacao);

EXCEPTION
    WHEN e_sem_leitura THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: Sem leitura disponível para zona ' || v_zona_id);
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: Zona ' || v_zona_id || ' não encontrada.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO inesperado: ' || SQLERRM);
END;
/

-- BLOCO 2: Listar zonas com score CRITICO
DECLARE
    v_count NUMBER := 0;
    CURSOR c_criticos IS
        SELECT z.nome, s.valor_score, s.dt_score
        FROM score_diario s
        JOIN zona_cidade z ON s.id_zona = z.id_zona
        WHERE s.classificacao = 'CRITICO'
        ORDER BY s.valor_score ASC;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 2: Zonas em Estado CRITICO ===');

    FOR r IN c_criticos LOOP
        v_count := v_count + 1;
        DBMS_OUTPUT.PUT_LINE(v_count || '. ' || r.nome ||
                             ' | Score: ' || r.valor_score ||
                             ' | Data: ' || TO_CHAR(r.dt_score, 'DD/MM/YYYY'));
    END LOOP;

    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Nenhuma zona em estado CRITICO.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Total zonas CRITICAS: ' || v_count);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO ao listar zonas críticas: ' || SQLERRM);
END;
/

-- BLOCO 3: Verificar se usuário recebeu recomendação hoje
DECLARE
    v_usuario_id    NUMBER := 3; -- Ana Paula (tem_problema_resp=1, tem_crianca=1)
    v_nome          VARCHAR2(150);
    v_count         NUMBER := 0;
    v_texto         VARCHAR2(1000);
    e_usuario_inv   EXCEPTION;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 3: Recomendações do Usuário ===');

    IF v_usuario_id <= 0 THEN RAISE e_usuario_inv; END IF;

    SELECT nome INTO v_nome
    FROM usuario WHERE id_usuario = v_usuario_id AND ativo = 1;

    SELECT COUNT(*) INTO v_count
    FROM recomendacao
    WHERE id_usuario = v_usuario_id
    AND TRUNC(dt_criacao) = TRUNC(SYSDATE);

    DBMS_OUTPUT.PUT_LINE('Usuário: ' || v_nome);

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('Recomendações hoje: ' || v_count);
        SELECT texto INTO v_texto
        FROM (SELECT texto FROM recomendacao
              WHERE id_usuario = v_usuario_id ORDER BY dt_criacao DESC)
        WHERE ROWNUM = 1;
        DBMS_OUTPUT.PUT_LINE('Última: ' || SUBSTR(v_texto, 1, 100));
    ELSE
        SELECT COUNT(*) INTO v_count FROM recomendacao WHERE id_usuario = v_usuario_id;
        DBMS_OUTPUT.PUT_LINE('Sem recomendação hoje. Total histórico: ' || v_count);
    END IF;
EXCEPTION
    WHEN e_usuario_inv THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: ID de usuário inválido.');
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: Usuário não encontrado ou inativo.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: ' || SQLERRM);
END;
/

-- BLOCO 4: Contar total de leituras por satélite
DECLARE
    v_sentinel  NUMBER := 0;
    v_ecostress NUMBER := 0;
    v_omi       NUMBER := 0;
    v_total     NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 4: Leituras por Satélite ===');

    SELECT COUNT(*) INTO v_sentinel
    FROM leitura_satelite WHERE satelite = 'SENTINEL_5P';

    SELECT COUNT(*) INTO v_ecostress
    FROM leitura_satelite WHERE satelite = 'ECOSTRESS';

    SELECT COUNT(*) INTO v_omi
    FROM leitura_satelite WHERE satelite = 'OMI';

    v_total := v_sentinel + v_ecostress + v_omi;

    IF v_total = 0 THEN RAISE NO_DATA_FOUND; END IF;

    DBMS_OUTPUT.PUT_LINE('SENTINEL_5P: ' || v_sentinel || ' leituras');
    DBMS_OUTPUT.PUT_LINE('ECOSTRESS:   ' || v_ecostress || ' leituras');
    DBMS_OUTPUT.PUT_LINE('OMI:         ' || v_omi || ' leituras');
    DBMS_OUTPUT.PUT_LINE('Total:       ' || v_total);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('AVISO: Nenhuma leitura de satélite registrada.');
    WHEN ZERO_DIVIDE THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: Divisão por zero.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: ' || SQLERRM);
END;
/

-- BLOCO 5: Pior e melhor dia de uma zona no histórico
DECLARE
    v_zona_id       NUMBER := 1;
    v_nome          VARCHAR2(100);
    v_pior          NUMBER;
    v_melhor        NUMBER;
    v_dt_pior       DATE;
    v_dt_melhor     DATE;
    v_total         NUMBER;
    e_sem_historico EXCEPTION;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 5: Análise Histórica de Zona ===');

    SELECT nome INTO v_nome FROM zona_cidade WHERE id_zona = v_zona_id;

    SELECT COUNT(*) INTO v_total FROM score_diario WHERE id_zona = v_zona_id;

    IF v_total = 0 THEN RAISE e_sem_historico; END IF;

    SELECT MIN(valor_score), MAX(valor_score)
    INTO v_pior, v_melhor
    FROM score_diario WHERE id_zona = v_zona_id;

    SELECT dt_score INTO v_dt_pior
    FROM score_diario
    WHERE id_zona = v_zona_id AND valor_score = v_pior AND ROWNUM = 1;

    SELECT dt_score INTO v_dt_melhor
    FROM score_diario
    WHERE id_zona = v_zona_id AND valor_score = v_melhor AND ROWNUM = 1;

    DBMS_OUTPUT.PUT_LINE('Zona: ' || v_nome);
    DBMS_OUTPUT.PUT_LINE('Dias analisados: ' || v_total);
    DBMS_OUTPUT.PUT_LINE('Pior:   ' || TO_CHAR(v_dt_pior, 'DD/MM/YYYY') || ' | Score: ' || v_pior);
    DBMS_OUTPUT.PUT_LINE('Melhor: ' || TO_CHAR(v_dt_melhor, 'DD/MM/YYYY') || ' | Score: ' || v_melhor);
    DBMS_OUTPUT.PUT_LINE('Variação: ' || (v_melhor - v_pior) || ' pontos');
EXCEPTION
    WHEN e_sem_historico THEN
        DBMS_OUTPUT.PUT_LINE('AVISO: Sem histórico para zona ' || v_zona_id);
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: Zona não encontrada.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: ' || SQLERRM);
END;
/

-- BLOCO 6: Validar consistência score vs classificação
DECLARE
    v_inconsistencias NUMBER := 0;
    v_total           NUMBER := 0;
    v_esperada        VARCHAR2(15);
    v_id_score        NUMBER;
    v_score_val       NUMBER;
    v_classe_atual    VARCHAR2(15);
    CURSOR c_scores IS
        SELECT id_score, valor_score, classificacao FROM score_diario;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== BLOCO 6: Validação de Consistência ===');

    OPEN c_scores;
    LOOP
        FETCH c_scores INTO v_id_score, v_score_val, v_classe_atual;
        EXIT WHEN c_scores%NOTFOUND;
        v_total := v_total + 1;

        IF v_score_val >= 80 THEN v_esperada := 'BOM';
        ELSIF v_score_val >= 60 THEN v_esperada := 'MODERADO';
        ELSIF v_score_val >= 40 THEN v_esperada := 'RUIM';
        ELSE v_esperada := 'CRITICO'; END IF;

        IF v_esperada != v_classe_atual THEN
            v_inconsistencias := v_inconsistencias + 1;
            DBMS_OUTPUT.PUT_LINE('INCONSISTÊNCIA id=' || v_id_score ||
                                 ' score=' || v_score_val ||
                                 ' esperado=' || v_esperada ||
                                 ' atual=' || v_classe_atual);
        END IF;
    END LOOP;
    CLOSE c_scores;

    DBMS_OUTPUT.PUT_LINE('Verificados: ' || v_total);
    IF v_inconsistencias = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ 100% consistentes.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Inconsistências: ' || v_inconsistencias);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        IF c_scores%ISOPEN THEN CLOSE c_scores; END IF;
        DBMS_OUTPUT.PUT_LINE('ERRO na validação: ' || SQLERRM);
END;
/

-- ============================================================
-- 4.2 — ESTRUTURAS DE DECISÃO (IF / ELSIF / ELSE + CASE)
-- ============================================================
-- Seção dedicada às estruturas condicionais exigidas pela rubrica
-- (item "Estrutura de decisão"). As regras RN02..RN05 e RN06..RN09
-- são aplicadas aqui de forma isolada e legível.

-- DECISÃO 1, 2 e 3: classificação do score, alerta OMS e perfil de risco
DECLARE
    v_zona_id   NUMBER := 2; -- Zona Leste (industrial)
    v_no2       NUMBER;
    v_temp      NUMBER;
    v_score     NUMBER;
    v_classe    VARCHAR2(15);
    v_alerta    VARCHAR2(30);
    v_conforto  VARCHAR2(30);
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== 4.2 DECISÃO: Avaliação de Zona ===');

    SELECT no2_valor, temp_valor, valor_score
    INTO   v_no2, v_temp, v_score
    FROM   score_diario
    WHERE  id_zona = v_zona_id
    ORDER BY dt_score DESC
    FETCH FIRST 1 ROW ONLY;

    -- DECISÃO 1: classificação por faixa de score (IF/ELSIF/ELSE)
    IF v_score >= 80 THEN
        v_classe := 'BOM';
    ELSIF v_score >= 60 THEN
        v_classe := 'MODERADO';
    ELSIF v_score >= 40 THEN
        v_classe := 'RUIM';
    ELSE
        v_classe := 'CRITICO';
    END IF;

    -- DECISÃO 2: alerta segundo limite OMS de NO₂ (RN06)
    IF v_no2 > 50 THEN
        v_alerta := 'EMERGENCIA';
    ELSIF v_no2 > 25 THEN
        v_alerta := 'ACIMA DO LIMITE OMS';
    ELSE
        v_alerta := 'DENTRO DO LIMITE';
    END IF;

    -- DECISÃO 3: conforto térmico (RN07)
    IF v_temp >= 38 THEN
        v_conforto := 'CALOR EXTREMO';
    ELSIF v_temp >= 30 THEN
        v_conforto := 'ACIMA DO CONFORTO';
    ELSE
        v_conforto := 'CONFORTAVEL';
    END IF;

    DBMS_OUTPUT.PUT_LINE('Score ' || v_score || ' -> ' || v_classe);
    DBMS_OUTPUT.PUT_LINE('NO2 ' || v_no2 || ' ppb -> ' || v_alerta);
    DBMS_OUTPUT.PUT_LINE('Temp ' || v_temp || 'C -> ' || v_conforto);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Sem score registrado para a zona ' || v_zona_id);
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO na avaliação: ' || SQLERRM);
END;
/

-- DECISÃO 4: recomendação personalizada por perfil de saúde (RN08/RN09)
DECLARE
    v_usuario_id  NUMBER := 3; -- Ana Paula (resp=1, criança=1)
    v_resp        NUMBER;
    v_crianca     NUMBER;
    v_exercicio   NUMBER;
    v_mensagem    VARCHAR2(200);
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== 4.2 DECISÃO 4: Perfil de Risco do Usuário ===');

    SELECT tem_problema_resp, tem_crianca, faz_exercicio
    INTO   v_resp, v_crianca, v_exercicio
    FROM   usuario
    WHERE  id_usuario = v_usuario_id;

    -- IF/ELSIF/ELSE encadeado priorizando o perfil mais vulnerável
    IF v_resp = 1 AND v_crianca = 1 THEN
        v_mensagem := 'Perfil de ALTA vulnerabilidade: respiratório + criança.';
    ELSIF v_resp = 1 THEN
        v_mensagem := 'Vulnerabilidade respiratória: priorizar alertas restritivos.';
    ELSIF v_crianca = 1 THEN
        v_mensagem := 'Responsável por criança: avisos de exposição infantil.';
    ELSIF v_exercicio = 1 THEN
        v_mensagem := 'Praticante de exercício: orientar melhor horário ao ar livre.';
    ELSE
        v_mensagem := 'Perfil padrão: recomendações gerais.';
    END IF;

    DBMS_OUTPUT.PUT_LINE(v_mensagem);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Usuário ' || v_usuario_id || ' não encontrado.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO no perfil: ' || SQLERRM);
END;
/

-- ============================================================
-- 4.4 — CURSORES EXPLÍCITOS (4 cursores)
-- ============================================================

-- CURSOR 1: Zonas com score médio < 60 nos últimos 7 dias
DECLARE
    CURSOR c_zonas_ruins IS
        SELECT z.nome,
               ROUND(AVG(s.valor_score), 2) AS media,
               COUNT(s.id_score) AS qtd_dias
        FROM score_diario s
        JOIN zona_cidade z ON s.id_zona = z.id_zona
        WHERE s.dt_score >= TRUNC(SYSDATE) - 7
        GROUP BY z.nome
        HAVING AVG(s.valor_score) < 60
        ORDER BY media ASC;
    v_rec c_zonas_ruins%ROWTYPE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CURSOR 1: Zonas Média Score < 60 (7 dias) ===');
    OPEN c_zonas_ruins;
    LOOP
        FETCH c_zonas_ruins INTO v_rec;
        EXIT WHEN c_zonas_ruins%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE('Zona: ' || v_rec.nome ||
                             ' | Média: ' || v_rec.media ||
                             ' | Dias: ' || v_rec.qtd_dias);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Total retornado: ' || c_zonas_ruins%ROWCOUNT);
    CLOSE c_zonas_ruins;
EXCEPTION
    WHEN OTHERS THEN
        IF c_zonas_ruins%ISOPEN THEN CLOSE c_zonas_ruins; END IF;
        DBMS_OUTPUT.PUT_LINE('ERRO Cursor 1: ' || SQLERRM);
END;
/

-- CURSOR 2: Usuários com problema respiratório em zona CRITICA
DECLARE
    CURSOR c_vulneraveis IS
        SELECT DISTINCT u.nome, u.email, z.nome AS zona, s.valor_score
        FROM usuario u
        JOIN recomendacao r  ON u.id_usuario = r.id_usuario
        JOIN score_diario s  ON r.id_score   = s.id_score
        JOIN zona_cidade z   ON s.id_zona    = z.id_zona
        WHERE u.tem_problema_resp = 1
        AND s.classificacao = 'CRITICO'
        ORDER BY s.valor_score ASC;
    v_rec   c_vulneraveis%ROWTYPE;
    v_count NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CURSOR 2: Vulneráveis Respiratórios em Zona CRITICA ===');
    OPEN c_vulneraveis;
    LOOP
        FETCH c_vulneraveis INTO v_rec;
        EXIT WHEN c_vulneraveis%NOTFOUND;
        v_count := v_count + 1;
        DBMS_OUTPUT.PUT_LINE(v_rec.nome || ' | ' || v_rec.zona || ' | Score: ' || v_rec.valor_score);
    END LOOP;
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Nenhum usuário vulnerável em zona crítica.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Em risco: ' || v_count || ' usuários.');
    END IF;
    CLOSE c_vulneraveis;
EXCEPTION
    WHEN OTHERS THEN
        IF c_vulneraveis%ISOPEN THEN CLOSE c_vulneraveis; END IF;
        DBMS_OUTPUT.PUT_LINE('ERRO Cursor 2: ' || SQLERRM);
END;
/

-- CURSOR 3: Leituras de NO₂ acima do limite OMS (25 ppb)
DECLARE
    CURSOR c_acima_oms IS
        SELECT z.nome,
               l.dt_captura,
               l.valor AS no2,
               ROUND(l.valor - 25, 2) AS excesso
        FROM leitura_satelite l
        JOIN zona_cidade z ON l.id_zona = z.id_zona
        WHERE l.tipo_dado = 'NO2'
        AND l.valor > 25
        ORDER BY l.valor DESC;
    v_rec   c_acima_oms%ROWTYPE;
    v_count NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CURSOR 3: NO₂ Acima do Limite OMS (>25 ppb) ===');
    OPEN c_acima_oms;
    LOOP
        FETCH c_acima_oms INTO v_rec;
        EXIT WHEN c_acima_oms%NOTFOUND;
        v_count := v_count + 1;
        DBMS_OUTPUT.PUT_LINE(v_count || '. ' || v_rec.nome ||
                             ' | NO₂: ' || v_rec.no2 || ' ppb' ||
                             ' | Excesso: +' || v_rec.excesso || ' ppb' ||
                             ' | ' || TO_CHAR(v_rec.dt_captura, 'DD/MM/YYYY'));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Total acima do limite OMS: ' || v_count);
    CLOSE c_acima_oms;
EXCEPTION
    WHEN OTHERS THEN
        IF c_acima_oms%ISOPEN THEN CLOSE c_acima_oms; END IF;
        DBMS_OUTPUT.PUT_LINE('ERRO Cursor 3: ' || SQLERRM);
END;
/

-- CURSOR 4: Top 3 zonas com mais alertas (ALERTA_HISTORICO — domínio .NET)
DECLARE
    CURSOR c_top_alertas IS
        SELECT zn.NOME, COUNT(a.ID_ALERTA) AS total,
               MAX(a.DT_ALERTA) AS ultimo
        FROM ALERTA_HISTORICO a
        JOIN ZONA_REFERENCIA_NET zn ON a.ID_ZONA = zn.ID_ZONA
        GROUP BY zn.NOME
        ORDER BY total DESC
        FETCH FIRST 3 ROWS ONLY;
    v_rec  c_top_alertas%ROWTYPE;
    v_rank NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CURSOR 4: Top 3 Zonas com Mais Alertas (.NET) ===');
    OPEN c_top_alertas;
    LOOP
        FETCH c_top_alertas INTO v_rec;
        EXIT WHEN c_top_alertas%NOTFOUND;
        v_rank := v_rank + 1;
        DBMS_OUTPUT.PUT_LINE('#' || v_rank || ' ' || v_rec.NOME ||
                             ' | Alertas: ' || v_rec.total ||
                             ' | Último: ' || TO_CHAR(v_rec.ultimo, 'DD/MM/YYYY'));
    END LOOP;
    IF v_rank = 0 THEN DBMS_OUTPUT.PUT_LINE('Nenhum alerta registrado.'); END IF;
    CLOSE c_top_alertas;
EXCEPTION
    WHEN OTHERS THEN
        IF c_top_alertas%ISOPEN THEN CLOSE c_top_alertas; END IF;
        DBMS_OUTPUT.PUT_LINE('ERRO Cursor 4: ' || SQLERRM);
END;
/

-- ============================================================
-- 4.3 — ESTRUTURAS DE REPETIÇÃO (4 loops)
-- ============================================================

-- LOOP 1: FOR LOOP — Calcular scores em lote para todas as zonas
DECLARE
    v_no2    NUMBER;
    v_temp   NUMBER;
    v_score  NUMBER;
    v_class  VARCHAR2(15);
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== LOOP 1: FOR — Scores em Lote ===');

    FOR r IN (SELECT id_zona, nome FROM zona_cidade WHERE ativo = 1 ORDER BY id_zona) LOOP
        BEGIN
            SELECT valor INTO v_no2
            FROM leitura_satelite
            WHERE id_zona = r.id_zona AND tipo_dado = 'NO2'
            ORDER BY dt_captura DESC FETCH FIRST 1 ROWS ONLY;

            SELECT valor INTO v_temp
            FROM leitura_satelite
            WHERE id_zona = r.id_zona AND tipo_dado = 'TEMP_SUPERFICIE'
            ORDER BY dt_captura DESC FETCH FIRST 1 ROWS ONLY;

            v_score := ROUND(
                (GREATEST(0, 1 - v_no2/50) * 0.60 +
                 GREATEST(0, 1 - GREATEST(0, (v_temp-30)/20)) * 0.40) * 100,
            1);

            IF v_score >= 80 THEN v_class := 'BOM';
            ELSIF v_score >= 60 THEN v_class := 'MODERADO';
            ELSIF v_score >= 40 THEN v_class := 'RUIM';
            ELSE v_class := 'CRITICO'; END IF;

            DBMS_OUTPUT.PUT_LINE('Zona: ' || r.nome || ' | Score: ' || v_score || ' | ' || v_class);
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Zona: ' || r.nome || ' | Sem dados de satélite');
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Lote concluído.');
END;
/

-- LOOP 2: WHILE LOOP — Processar alertas não confirmados
DECLARE
    v_id        NUMBER;
    v_zona      NVARCHAR2(100);
    v_nivel     NVARCHAR2(15);
    v_pendentes NUMBER;
    v_proc      NUMBER := 0;
    v_max       NUMBER := 10;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== LOOP 2: WHILE — Alertas Pendentes ===');

    SELECT COUNT(*) INTO v_pendentes
    FROM ALERTA_HISTORICO WHERE CONFIRMADO = 0;

    DBMS_OUTPUT.PUT_LINE('Pendentes: ' || v_pendentes);

    WHILE v_pendentes > 0 AND v_proc < v_max LOOP
        SELECT a.ID_ALERTA, zn.NOME, a.NIVEL_ALERTA
        INTO v_id, v_zona, v_nivel
        FROM ALERTA_HISTORICO a
        JOIN ZONA_REFERENCIA_NET zn ON a.ID_ZONA = zn.ID_ZONA
        WHERE a.CONFIRMADO = 0 AND ROWNUM = 1;

        DBMS_OUTPUT.PUT_LINE('Alerta #' || v_id || ' | ' || v_zona || ' | ' || v_nivel);
        v_proc := v_proc + 1;

        SELECT COUNT(*) INTO v_pendentes
        FROM ALERTA_HISTORICO WHERE CONFIRMADO = 0 AND ID_ALERTA > v_id;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Verificados: ' || v_proc);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Todos os alertas processados.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO no while loop: ' || SQLERRM);
END;
/

-- LOOP 3: LOOP...EXIT WHEN — Buscar primeiro dia crítico no histórico
DECLARE
    v_data      DATE := TRUNC(SYSDATE);
    v_limite    DATE := TRUNC(SYSDATE) - 30;
    v_score     NUMBER;
    v_zona_id   NUMBER := 1;
    v_nome      VARCHAR2(100);
    v_dias      NUMBER := 0;
    v_achou     BOOLEAN := FALSE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== LOOP 3: LOOP..EXIT WHEN — Busca Dia Crítico ===');

    SELECT nome INTO v_nome FROM zona_cidade WHERE id_zona = v_zona_id;

    LOOP
        EXIT WHEN v_data < v_limite;

        BEGIN
            SELECT valor_score INTO v_score
            FROM score_diario
            WHERE id_zona = v_zona_id AND dt_score = v_data;

            v_dias := v_dias + 1;

            IF v_score < 40 THEN
                DBMS_OUTPUT.PUT_LINE('Dia crítico: ' || TO_CHAR(v_data, 'DD/MM/YYYY') ||
                                     ' | Score: ' || v_score);
                v_achou := TRUE;
                EXIT;
            END IF;
        EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
        END;

        v_data := v_data - 1;
    END LOOP;

    IF NOT v_achou THEN
        DBMS_OUTPUT.PUT_LINE('Sem dia crítico nos últimos 30 dias para ' || v_nome);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Dias verificados: ' || v_dias);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO no loop histórico: ' || SQLERRM);
END;
/

-- LOOP 4: FOR com cursor — Relatório de alertas por zona
DECLARE
    CURSOR c_rel IS
        SELECT zn.NOME,
               COUNT(a.ID_ALERTA) AS total,
               SUM(CASE WHEN a.CONFIRMADO = 1 THEN 1 ELSE 0 END) AS confirmados
        FROM ZONA_REFERENCIA_NET zn
        LEFT JOIN ALERTA_HISTORICO a ON zn.ID_ZONA = a.ID_ZONA
        GROUP BY zn.NOME
        ORDER BY total DESC NULLS LAST;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== LOOP 4: FOR com CURSOR — Alertas por Zona ===');
    FOR r IN c_rel LOOP
        DBMS_OUTPUT.PUT_LINE('Zona: ' || r.NOME ||
                             ' | Total: ' || NVL(TO_CHAR(r.total),'0') ||
                             ' | Confirmados: ' || NVL(TO_CHAR(r.confirmados),'0'));
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO Loop 4: ' || SQLERRM);
END;
/

-- ============================================================
-- 4.5 — PROCEDURES (substituem as do schema original
--       adicionando lógica de batch e Exception blocks)
-- ============================================================

CREATE OR REPLACE PROCEDURE calcular_score_zona (p_zona_id IN NUMBER) AS
    v_no2        NUMBER(10,4);
    v_temp       NUMBER(10,4);
    v_score_no2  NUMBER;
    v_score_temp NUMBER;
    v_score      NUMBER(5,2);
    v_class      VARCHAR2(15);
BEGIN
    SELECT valor INTO v_no2
    FROM leitura_satelite
    WHERE id_zona = p_zona_id AND tipo_dado = 'NO2'
    ORDER BY dt_captura DESC
    FETCH FIRST 1 ROWS ONLY;

    SELECT valor INTO v_temp
    FROM leitura_satelite
    WHERE id_zona = p_zona_id AND tipo_dado = 'TEMP_SUPERFICIE'
    ORDER BY dt_captura DESC
    FETCH FIRST 1 ROWS ONLY;

    v_score_no2  := GREATEST(0, 1 - (v_no2  / 50));
    v_score_temp := GREATEST(0, 1 - GREATEST(0, (v_temp - 30) / 20));
    v_score      := ROUND((v_score_no2 * 0.60 + v_score_temp * 0.40) * 100, 1);

    SELECT CASE
        WHEN v_score >= 80 THEN 'BOM'
        WHEN v_score >= 60 THEN 'MODERADO'
        WHEN v_score >= 40 THEN 'RUIM'
        ELSE 'CRITICO'
    END INTO v_class FROM DUAL;

    INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
    VALUES (p_zona_id, TRUNC(SYSDATE), v_score, v_class, v_no2, v_temp);

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('[calcular_score_zona] Zona ' || p_zona_id ||
                         ' | Score: ' || v_score || ' | ' || v_class);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('[calcular_score_zona] Sem leituras para zona ' || p_zona_id);
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('[calcular_score_zona] Score já existe para zona ' ||
                             p_zona_id || ' hoje.');
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END calcular_score_zona;
/

CREATE OR REPLACE PROCEDURE registrar_recomendacao (
    p_score_id   IN NUMBER,
    p_usuario_id IN NUMBER,
    p_texto      IN VARCHAR2,
    p_icone      IN VARCHAR2
) AS
BEGIN
    INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
    VALUES (p_score_id, p_usuario_id, p_texto, p_icone);

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('[registrar_recomendacao] Recomendação inserida para usuário '
                         || p_usuario_id);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END registrar_recomendacao;
/

-- Procedure adicional: processar lote (requisito FIAP — não existe no schema)
CREATE OR REPLACE PROCEDURE processar_lote_zonas AS
    v_ok    NUMBER := 0;
    v_erro  NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Lote diário: ' || TO_CHAR(SYSDATE,'DD/MM/YYYY HH24:MI') || ' ===');
    FOR z IN (SELECT id_zona FROM zona_cidade WHERE ativo = 1) LOOP
        BEGIN
            calcular_score_zona(z.id_zona);
            v_ok := v_ok + 1;
        EXCEPTION WHEN OTHERS THEN
            v_erro := v_erro + 1;
            INSERT INTO log_consulta (id_zona, endpoint, ip_origem)
            VALUES (z.id_zona, 'LOTE/ERRO: ' || SUBSTR(SQLERRM,1,150), 'INTERNAL');
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('OK: ' || v_ok || ' | Erros: ' || v_erro);
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20005, 'Erro crítico no lote: ' || SQLERRM);
END processar_lote_zonas;
/

-- ============================================================
-- 4.6 — FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION get_classificacao(p_score IN NUMBER)
RETURN VARCHAR2 IS
BEGIN
    IF p_score IS NULL THEN RETURN 'INDEFINIDO'; END IF;
    IF p_score >= 80 THEN RETURN 'BOM';
    ELSIF p_score >= 60 THEN RETURN 'MODERADO';
    ELSIF p_score >= 40 THEN RETURN 'RUIM';
    ELSE RETURN 'CRITICO'; END IF;
EXCEPTION
    WHEN OTHERS THEN RETURN 'ERRO';
END get_classificacao;
/

CREATE OR REPLACE FUNCTION get_texto_recomendacao(
    p_score         IN NUMBER,
    p_faz_exercicio IN NUMBER,
    p_tem_crianca   IN NUMBER,
    p_tem_resp      IN NUMBER
) RETURN VARCHAR2 IS
    v_class VARCHAR2(15);
    v_texto VARCHAR2(1000);
BEGIN
    v_class := get_classificacao(p_score);

    IF v_class = 'BOM' THEN
        v_texto := 'Ar excelente. Score ' || ROUND(p_score,1) || '.';
        IF p_faz_exercicio = 1 THEN v_texto := v_texto || ' Ótimo para atividades físicas.'; END IF;
    ELSIF v_class = 'MODERADO' THEN
        v_texto := 'Ar moderado. Score ' || ROUND(p_score,1) || '.';
        IF p_tem_crianca = 1 THEN v_texto := v_texto || ' Limite exposição infantil.'; END IF;
    ELSIF v_class = 'RUIM' THEN
        v_texto := 'Ar ruim. Score ' || ROUND(p_score,1) || '. Reduza exposição ao exterior.';
        IF p_tem_resp = 1 THEN v_texto := v_texto || ' RISCO: portadores de asma/DPOC devem evitar sair.'; END IF;
        IF p_tem_crianca = 1 THEN v_texto := v_texto || ' Crianças não devem praticar atividades externas.'; END IF;
    ELSE
        v_texto := 'CRÍTICO. Score ' || ROUND(p_score,1) || '. Não saia sem necessidade.';
        IF p_tem_resp = 1 THEN v_texto := v_texto || ' EMERGÊNCIA RESPIRATÓRIA. Use medicação preventiva.'; END IF;
        IF p_tem_crianca = 1 THEN v_texto := v_texto || ' Crianças em ambiente fechado.'; END IF;
    END IF;

    RETURN SUBSTR(v_texto, 1, 1000);
EXCEPTION
    WHEN OTHERS THEN RETURN 'Erro: ' || SQLERRM;
END get_texto_recomendacao;
/

CREATE OR REPLACE FUNCTION calcular_media_score_zona(
    p_zona_id IN NUMBER,
    p_dias    IN NUMBER DEFAULT 7
) RETURN NUMBER IS
    v_media NUMBER;
BEGIN
    SELECT AVG(valor_score)
    INTO v_media
    FROM score_diario
    WHERE id_zona = p_zona_id
    AND dt_score >= TRUNC(SYSDATE) - p_dias;

    RETURN ROUND(NVL(v_media, 0), 2);
EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN 0;
    WHEN OTHERS THEN RETURN -1;
END calcular_media_score_zona;
/

-- ============================================================
-- 4.7 — TRIGGERS
-- ============================================================

-- Trigger 1 e 2 já existem no schema (trg_valida_score, trg_log_score_consulta)
-- Recriados aqui para garantir a versão completa da entrega:

CREATE OR REPLACE TRIGGER trg_valida_score
    BEFORE INSERT OR UPDATE ON score_diario
    FOR EACH ROW
DECLARE
    v_esperada VARCHAR2(15);
BEGIN
    IF :NEW.valor_score < 0 OR :NEW.valor_score > 100 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Score fora do range 0-100: ' || TO_CHAR(:NEW.valor_score));
    END IF;

    -- Valida consistência score x classificação
    IF :NEW.valor_score >= 80 THEN v_esperada := 'BOM';
    ELSIF :NEW.valor_score >= 60 THEN v_esperada := 'MODERADO';
    ELSIF :NEW.valor_score >= 40 THEN v_esperada := 'RUIM';
    ELSE v_esperada := 'CRITICO'; END IF;

    IF :NEW.classificacao != v_esperada THEN
        RAISE_APPLICATION_ERROR(-20002,
            'Inconsistência: score ' || :NEW.valor_score ||
            ' exige ' || v_esperada || ', recebeu ' || :NEW.classificacao);
    END IF;
END trg_valida_score;
/

CREATE OR REPLACE TRIGGER trg_log_score_consulta
    AFTER INSERT ON score_diario
    FOR EACH ROW
BEGIN
    INSERT INTO log_consulta (id_zona, endpoint, dt_consulta)
    VALUES (:NEW.id_zona, 'SCHEDULER/calcular_score_zona', SYSTIMESTAMP);
EXCEPTION
    WHEN OTHERS THEN NULL;
END trg_log_score_consulta;
/

-- Trigger 3: alerta automático para score CRITICO (novo — requisito FIAP)
CREATE OR REPLACE TRIGGER trg_alerta_critico
    AFTER INSERT ON score_diario
    FOR EACH ROW
    WHEN (NEW.classificacao = 'CRITICO')
BEGIN
    INSERT INTO ALERTA_HISTORICO (
        ID_ALERTA, ID_ZONA, NIVEL_ALERTA, SCORE_REGISTRADO,
        NO2_REGISTRADO, TEXTO_RECOMENDACAO, DT_ALERTA, CONFIRMADO)
    VALUES (
        SEQ_ALERTA_HISTORICO.NEXTVAL,
        :NEW.id_zona,
        'EMERGENCIA',
        :NEW.valor_score,
        NVL(:NEW.no2_valor, 0),
        'Alerta gerado automaticamente. Score: ' || :NEW.valor_score ||
        ' | NO₂: ' || NVL(TO_CHAR(:NEW.no2_valor),'N/A') || ' ppb',
        TRUNC(SYSDATE),
        0
    );
EXCEPTION
    WHEN OTHERS THEN NULL;
END trg_alerta_critico;
/

-- ============================================================
-- 4.8 — PACKAGE PKG_PULSO_URBANO
-- ============================================================

CREATE OR REPLACE PACKAGE PKG_PULSO_URBANO AS
    C_LIMITE_NO2_OMS   CONSTANT NUMBER := 25;
    C_TEMP_CONFORTAVEL CONSTANT NUMBER := 30;
    C_PESO_NO2         CONSTANT NUMBER := 0.60;
    C_PESO_TEMP        CONSTANT NUMBER := 0.40;

    FUNCTION get_classificacao(p_score IN NUMBER) RETURN VARCHAR2;

    FUNCTION get_texto_recomendacao(
        p_score         IN NUMBER,
        p_faz_exercicio IN NUMBER,
        p_tem_crianca   IN NUMBER,
        p_tem_resp      IN NUMBER
    ) RETURN VARCHAR2;

    FUNCTION calcular_media_score_zona(
        p_zona_id IN NUMBER,
        p_dias    IN NUMBER DEFAULT 7
    ) RETURN NUMBER;

    PROCEDURE calcular_score_zona(p_zona_id IN NUMBER);

    PROCEDURE registrar_recomendacao(
        p_score_id   IN NUMBER,
        p_usuario_id IN NUMBER,
        p_texto      IN VARCHAR2,
        p_icone      IN VARCHAR2
    );
END PKG_PULSO_URBANO;
/

CREATE OR REPLACE PACKAGE BODY PKG_PULSO_URBANO AS

    FUNCTION get_classificacao(p_score IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_score IS NULL THEN RETURN 'INDEFINIDO'; END IF;
        IF p_score >= 80 THEN RETURN 'BOM';
        ELSIF p_score >= 60 THEN RETURN 'MODERADO';
        ELSIF p_score >= 40 THEN RETURN 'RUIM';
        ELSE RETURN 'CRITICO'; END IF;
    END get_classificacao;

    FUNCTION get_texto_recomendacao(
        p_score IN NUMBER, p_faz_exercicio IN NUMBER,
        p_tem_crianca IN NUMBER, p_tem_resp IN NUMBER
    ) RETURN VARCHAR2 IS
        v_class VARCHAR2(15); v_txt VARCHAR2(1000);
    BEGIN
        v_class := get_classificacao(p_score);
        IF v_class = 'BOM' THEN
            v_txt := '[PKG] Ar excelente. Score ' || ROUND(p_score,1) || '.';
            IF p_faz_exercicio=1 THEN v_txt := v_txt || ' Exercício OK.'; END IF;
        ELSIF v_class = 'MODERADO' THEN
            v_txt := '[PKG] Ar moderado. Score ' || ROUND(p_score,1) || '.';
            IF p_tem_crianca=1 THEN v_txt := v_txt || ' Limite exposição infantil.'; END IF;
        ELSIF v_class = 'RUIM' THEN
            v_txt := '[PKG] Ar ruim. Score ' || ROUND(p_score,1) || '.';
            IF p_tem_resp=1 THEN v_txt := v_txt || ' Risco respiratório.'; END IF;
        ELSE
            v_txt := '[PKG] CRÍTICO! Score ' || ROUND(p_score,1) || '.';
            IF p_tem_resp=1 THEN v_txt := v_txt || ' EMERGÊNCIA RESP.'; END IF;
            IF p_tem_crianca=1 THEN v_txt := v_txt || ' Crianças em casa.'; END IF;
        END IF;
        RETURN SUBSTR(v_txt,1,1000);
    EXCEPTION WHEN OTHERS THEN RETURN 'ERRO: ' || SQLERRM; END get_texto_recomendacao;

    FUNCTION calcular_media_score_zona(p_zona_id IN NUMBER, p_dias IN NUMBER DEFAULT 7)
    RETURN NUMBER IS
        v_m NUMBER;
    BEGIN
        SELECT AVG(valor_score) INTO v_m FROM score_diario
        WHERE id_zona = p_zona_id AND dt_score >= TRUNC(SYSDATE) - p_dias;
        RETURN ROUND(NVL(v_m,0),2);
    EXCEPTION WHEN OTHERS THEN RETURN -1; END calcular_media_score_zona;

    PROCEDURE calcular_score_zona(p_zona_id IN NUMBER) AS
        v_no2 NUMBER; v_temp NUMBER;
        v_sn NUMBER; v_st NUMBER;
        v_score NUMBER(5,2); v_class VARCHAR2(15);
    BEGIN
        SELECT valor INTO v_no2 FROM leitura_satelite
        WHERE id_zona=p_zona_id AND tipo_dado='NO2'
        ORDER BY dt_captura DESC FETCH FIRST 1 ROWS ONLY;

        SELECT valor INTO v_temp FROM leitura_satelite
        WHERE id_zona=p_zona_id AND tipo_dado='TEMP_SUPERFICIE'
        ORDER BY dt_captura DESC FETCH FIRST 1 ROWS ONLY;

        v_sn    := GREATEST(0, 1 - v_no2/50);
        v_st    := GREATEST(0, 1 - GREATEST(0,(v_temp-C_TEMP_CONFORTAVEL)/20));
        v_score := ROUND((v_sn*C_PESO_NO2 + v_st*C_PESO_TEMP)*100, 1);
        v_class := get_classificacao(v_score);

        INSERT INTO score_diario (id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
        VALUES (p_zona_id, TRUNC(SYSDATE), v_score, v_class, v_no2, v_temp);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001,'[PKG] Sem leituras para zona '||p_zona_id);
        WHEN DUP_VAL_ON_INDEX THEN
            DBMS_OUTPUT.PUT_LINE('[PKG] Score já existe hoje para zona '||p_zona_id);
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END calcular_score_zona;

    PROCEDURE registrar_recomendacao(
        p_score_id IN NUMBER, p_usuario_id IN NUMBER,
        p_texto IN VARCHAR2, p_icone IN VARCHAR2
    ) AS
    BEGIN
        INSERT INTO recomendacao (id_score, id_usuario, texto, icone)
        VALUES (p_score_id, p_usuario_id, p_texto, p_icone);
        COMMIT;
    EXCEPTION WHEN OTHERS THEN ROLLBACK; RAISE;
    END registrar_recomendacao;

END PKG_PULSO_URBANO;
/

-- ============================================================
-- SEÇÃO 5 — MANIPULAÇÃO TABELA ↔ VARIÁVEL
-- ============================================================

DECLARE
    v_zona_id       NUMBER := 4; -- Zona Norte (BOM)
    v_score_atual   NUMBER;
    v_class_atual   VARCHAR2(15);
    v_nome_zona     VARCHAR2(100);
    v_nova_no2      NUMBER := 16.1;
    v_nova_temp     NUMBER := 28.4;
    v_novo_score    NUMBER;
    v_nova_class    VARCHAR2(15);
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== SEÇÃO 5: Manipulação Tabela ↔ Variável ===');

    -- 5.1 SELECT INTO — tabela para variável
    SELECT s.valor_score, s.classificacao, z.nome
    INTO v_score_atual, v_class_atual, v_nome_zona
    FROM score_diario s
    JOIN zona_cidade z ON s.id_zona = z.id_zona
    WHERE s.id_zona = v_zona_id
    ORDER BY s.dt_score DESC
    FETCH FIRST 1 ROW ONLY;

    DBMS_OUTPUT.PUT_LINE('SELECT INTO: ' || v_nome_zona ||
                         ' | Score atual: ' || v_score_atual ||
                         ' | ' || v_class_atual);

    -- 5.2 INSERT com variável — nova leitura de satélite
    INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
    VALUES (v_zona_id, 'NO2', CAST(TRUNC(SYSDATE) AS TIMESTAMP),
            'SENTINEL_5P', v_nova_no2, 'ppb');

    INSERT INTO leitura_satelite (id_zona, tipo_dado, dt_captura, satelite, valor, unidade)
    VALUES (v_zona_id, 'TEMP_SUPERFICIE', CAST(TRUNC(SYSDATE) AS TIMESTAMP),
            'ECOSTRESS', v_nova_temp, 'celsius');

    DBMS_OUTPUT.PUT_LINE('INSERT com variável: Novas leituras inseridas para ' || v_nome_zona);

    -- 5.3 UPDATE com variável — recalcula score com novos dados
    v_novo_score := ROUND(
        (GREATEST(0, 1 - v_nova_no2/50) * 0.60 +
         GREATEST(0, 1 - GREATEST(0,(v_nova_temp-30)/20)) * 0.40) * 100,
    1);
    v_nova_class := PKG_PULSO_URBANO.get_classificacao(v_novo_score);

    UPDATE score_diario
    SET valor_score = v_novo_score,
        classificacao = v_nova_class,
        no2_valor = v_nova_no2,
        temp_valor = v_nova_temp
    WHERE id_zona = v_zona_id
    AND dt_score = TRUNC(SYSDATE) - 1;

    DBMS_OUTPUT.PUT_LINE('UPDATE com variável: Score atualizado → ' ||
                         v_novo_score || ' (' || v_nova_class || ')' ||
                         ' | Linhas afetadas: ' || SQL%ROWCOUNT);

    -- 5.4 DELETE com variável — remove leituras antigas > 90 dias
    DELETE FROM leitura_satelite
    WHERE dt_captura < CAST(TRUNC(SYSDATE) - 90 AS TIMESTAMP);

    DBMS_OUTPUT.PUT_LINE('DELETE com variável: Leituras > 90 dias removidas. ' ||
                         SQL%ROWCOUNT || ' linhas.');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('COMMIT realizado.');
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Sem registro para manipulação nesta data.');
        ROLLBACK;
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Leitura já existe para esta zona/data/tipo — ignorando INSERT.');
        ROLLBACK;
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRO: ' || SQLERRM);
        ROLLBACK;
END;
/

-- ============================================================
-- SEÇÃO 6 — 5 RELATÓRIOS SQL COM JOIN
-- ============================================================

-- RELATÓRIO 1: Score atual por zona com classificação e fonte do dado
-- JOIN: score_diario + zona_cidade + leitura_satelite
SELECT
    z.nome                               AS zona,
    z.municipio,
    TO_CHAR(s.dt_score, 'DD/MM/YYYY')   AS data_score,
    s.no2_valor                          AS no2_ppb,
    s.temp_valor                         AS temp_celsius,
    s.valor_score                        AS score,
    s.classificacao,
    l.satelite                           AS fonte_no2
FROM score_diario s
JOIN zona_cidade z ON s.id_zona = z.id_zona
LEFT JOIN leitura_satelite l ON l.id_zona = s.id_zona
    AND l.tipo_dado = 'NO2'
    AND l.dt_captura = (
        SELECT MAX(l2.dt_captura) FROM leitura_satelite l2
        WHERE l2.id_zona = s.id_zona AND l2.tipo_dado = 'NO2'
        AND l2.dt_captura <= CAST(s.dt_score AS TIMESTAMP)
    )
ORDER BY s.valor_score ASC;

-- RELATÓRIO 2: Usuários em zona CRITICA (com dados do usuário + recomendação)
-- JOIN: recomendacao + usuario + score_diario + zona_cidade
SELECT
    u.nome                               AS usuario,
    u.email,
    z.nome                               AS zona,
    s.valor_score,
    s.classificacao,
    TO_CHAR(r.dt_criacao, 'DD/MM/YYYY') AS data_recomendacao,
    SUBSTR(r.texto, 1, 80) || '...'     AS texto_resumido
FROM recomendacao r
JOIN usuario u       ON r.id_usuario = u.id_usuario
JOIN score_diario s  ON r.id_score   = s.id_score
JOIN zona_cidade z   ON s.id_zona    = z.id_zona
WHERE s.classificacao = 'CRITICO'
ORDER BY r.dt_criacao DESC;

-- RELATÓRIO 3: Top 5 zonas mais poluídas (média NO₂)
-- JOIN: leitura_satelite + zona_cidade, GROUP BY + ORDER BY
SELECT
    z.nome,
    z.municipio,
    COUNT(l.valor)              AS qtd_leituras,
    ROUND(AVG(l.valor), 2)     AS media_no2_ppb,
    ROUND(MAX(l.valor), 2)     AS pico_no2_ppb,
    CASE
        WHEN AVG(l.valor) > 25 THEN 'ACIMA DO LIMITE OMS'
        ELSE 'Dentro do limite OMS'
    END                         AS status_oms
FROM leitura_satelite l
JOIN zona_cidade z ON l.id_zona = z.id_zona
WHERE l.tipo_dado = 'NO2'
AND l.dt_captura >= CAST(TRUNC(SYSDATE) - 30 AS TIMESTAMP)
GROUP BY z.nome, z.municipio
ORDER BY media_no2_ppb DESC
FETCH FIRST 5 ROWS ONLY;

-- RELATÓRIO 4: Histórico de scores por usuário nos últimos 7 dias
-- JOIN: score_diario + recomendacao + usuario + zona_cidade
SELECT
    u.nome                               AS usuario,
    z.nome                               AS zona,
    TO_CHAR(s.dt_score, 'DD/MM/YYYY')   AS data,
    s.valor_score                        AS score,
    s.classificacao,
    SUBSTR(r.texto, 1, 70) || '...'     AS recomendacao
FROM usuario u
JOIN recomendacao r  ON u.id_usuario = r.id_usuario
JOIN score_diario s  ON r.id_score   = s.id_score
JOIN zona_cidade z   ON s.id_zona    = z.id_zona
WHERE s.dt_score >= TRUNC(SYSDATE) - 7
ORDER BY u.nome, s.dt_score DESC;

-- RELATÓRIO 5: Comparativo NO₂ vs temperatura por zona (pivot em leitura_satelite)
SELECT
    z.nome                                                  AS zona,
    TO_CHAR(no2.dt_captura, 'DD/MM/YYYY')                  AS data_leitura,
    ROUND(no2.valor, 2)                                     AS no2_ppb,
    ROUND(temp.valor, 2)                                    AS temp_celsius,
    CASE
        WHEN no2.valor > 25 AND temp.valor > 35 THEN 'DUPLO RISCO'
        WHEN no2.valor > 25                     THEN 'RISCO NO₂'
        WHEN temp.valor > 35                    THEN 'RISCO TÉRMICO'
        ELSE 'OK'
    END                                                     AS status,
    ROUND(
        (GREATEST(0,1-no2.valor/50)*0.60 +
         GREATEST(0,1-GREATEST(0,(temp.valor-30)/20))*0.40)*100
    , 1)                                                    AS score_estimado
FROM leitura_satelite no2
JOIN leitura_satelite temp
    ON no2.id_zona = temp.id_zona
   AND TRUNC(no2.dt_captura) = TRUNC(temp.dt_captura)
   AND temp.tipo_dado = 'TEMP_SUPERFICIE'
JOIN zona_cidade z ON no2.id_zona = z.id_zona
WHERE no2.tipo_dado = 'NO2'
ORDER BY z.nome, no2.dt_captura DESC;

-- ============================================================
-- SEÇÃO 7 — MODELAGEM NoSQL (MongoDB)
-- ============================================================

/*
  MODELAGEM NoSQL — Entidade RECOMENDACAO no MongoDB
  ====================================================

  JUSTIFICATIVA DE USO NoSQL:
  1. Esquema variável: cada recomendação pode ter campos extras
     dependendo do perfil do usuário (resp, criança, exercício)
  2. Alto volume de escrita append-only (1 rec/usuário/dia/zona)
  3. Consultas por usuário são hot path — índice por id_usuario
     tem latência muito menor que JOIN relacional nessa escala
  4. Dados imutáveis após geração — perfeito para documentos MongoDB

  QUANDO USAR RELACIONAL vs NoSQL neste domínio:
  - RELACIONAL (Oracle): USUARIO, ZONA_CIDADE, LEITURA_SATELITE,
    SCORE_DIARIO → integridade referencial, cálculos agregados,
    joins analíticos com garantia ACID
  - NoSQL (MongoDB): RECOMENDACAO, LOG_CONSULTA, ALERTA_HISTORICO
    → alta cardinalidade, esquema variável, acesso por chave primária

  DOCUMENTO EXEMPLO — coleção: recomendacoes
  db.recomendacoes.insertOne({
    _id: ObjectId("664a1f3c2b4f8a1e3d9c0001"),
    id_rec: 1,
    dt_criacao: ISODate("2026-05-30T08:15:00Z"),
    dt_entrega: ISODate("2026-05-30T08:15:05Z"),
    icone: "alert-red",
    score_context: {
      id_score: 1,
      valor_score: 35.4,
      classificacao: "CRITICO",
      zona: {
        id_zona: 1,
        nome: "Centro",
        municipio: "São Paulo",
        lat: -23.5505,
        lon: -46.6333
      },
      dados_satelite: {
        no2_ppb: 42.5,
        temp_celsius: 36.8,
        satelite_no2: "SENTINEL_5P",
        satelite_temp: "ECOSTRESS"
      }
    },
    usuario: {
      id_usuario: 3,
      nome: "Ana Paula Rodrigues",
      perfil: {
        faz_exercicio: true,
        tem_crianca: true,
        tem_problema_resp: true
      }
    },
    texto: "ALERTA CRÍTICO: Ar perigoso no Centro. Score 35.4. Portadores de asma: use medicação. Crianças em ambientes fechados.",
    tags: ["CRITICO", "RESP", "CRIANCA", "SP-CENTRO"]
  });

  ÍNDICES:
  db.recomendacoes.createIndex(
    { "usuario.id_usuario": 1, "dt_criacao": -1 },
    { name: "idx_usuario_dt" }
  );
  // Busca rápida: recomendações de um usuário, mais recente primeiro

  db.recomendacoes.createIndex(
    { "score_context.classificacao": 1 },
    { name: "idx_classificacao" }
  );
  // Dashboard: filtrar por tipo de alerta

  db.recomendacoes.createIndex(
    { "score_context.zona.id_zona": 1, "dt_criacao": -1 },
    { name: "idx_zona_dt" }
  );
  // Consultas por zona e período para relatórios gerenciais
*/

-- ============================================================
-- VERIFICAÇÃO FINAL
-- ============================================================

SELECT 'usuario'              AS tabela, COUNT(*) AS registros FROM usuario             UNION ALL
SELECT 'zona_cidade'          AS tabela, COUNT(*) AS registros FROM zona_cidade          UNION ALL
SELECT 'leitura_satelite'     AS tabela, COUNT(*) AS registros FROM leitura_satelite     UNION ALL
SELECT 'score_diario'         AS tabela, COUNT(*) AS registros FROM score_diario          UNION ALL
SELECT 'recomendacao'         AS tabela, COUNT(*) AS registros FROM recomendacao          UNION ALL
SELECT 'log_consulta'         AS tabela, COUNT(*) AS registros FROM log_consulta          UNION ALL
SELECT 'ZONA_REFERENCIA_NET'  AS tabela, COUNT(*) AS registros FROM ZONA_REFERENCIA_NET  UNION ALL
SELECT 'ALERTA_HISTORICO'     AS tabela, COUNT(*) AS registros FROM ALERTA_HISTORICO;
-- Esperado: total >= 80 registros

-- Teste das functions
SELECT
    get_classificacao(90)   AS bom,
    get_classificacao(70)   AS moderado,
    get_classificacao(50)   AS ruim,
    get_classificacao(30)   AS critico
FROM DUAL;

SELECT
    PKG_PULSO_URBANO.get_classificacao(85)                AS pkg_bom,
    PKG_PULSO_URBANO.calcular_media_score_zona(1, 30)     AS media_centro_30d
FROM DUAL;

-- ============================================================
-- FIM DO ARQUIVO — PULSO URBANO GS 2026/1
-- Felipe Ferrete · RM 562999
-- ============================================================
