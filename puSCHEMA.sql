-- =============================================================================
--  PULSO URBANO — SCHEMA COMPLETO UNIFICADO v1.0
--  Oracle 19c / 23c Free Edition (XEPDB1 / FREEPDB1)
--
--  Este arquivo documenta o banco de dados compartilhado entre os dois backends.
--  Cada seção indica claramente o proprietário do domínio.
--
--  ┌──────────────────────────────────────────────────────┐
--  │  DIVISÃO DE DOMÍNIOS                                 │
--  │                                                      │
--  │  Java API  (Spring Boot 3.2, porta 8080)             │
--  │    Sequences : seq_usuario, seq_zona, seq_score,     │
--  │                seq_recomendacao, seq_log             │
--  │    Tabelas   : USUARIO, ZONA_CIDADE,                 │
--  │                LEITURA_SATELITE, SCORE_DIARIO,       │
--  │                RECOMENDACAO, LOG_CONSULTA            │
--  │    Triggers  : trg_log_score_consulta, trg_valida_score │
--  │    Procedures: calcular_score_zona,                  │
--  │                registrar_recomendacao                │
--  │                                                      │
--  │  .NET API  (ASP.NET Core 8, porta 5000)              │
--  │    Sequences : SEQ_ZONA_REFERENCIA,                  │
--  │                SEQ_ALERTA_HISTORICO  (HiLo, +10)     │
--  │    Tabelas   : ZONA_REFERENCIA_NET, ALERTA_HISTORICO │
--  └──────────────────────────────────────────────────────┘
--
--  REGRA FUNDAMENTAL: zero FKs cruzadas entre APIs.
--    ZONA_REFERENCIA_NET espelha ZONA_CIDADE via seed determinístico
--    (Random seed 562999), mas não há FOREIGN KEY entre elas.
--    Cada API mantém sua própria integridade referencial.
--
--  ORDEM DE EXECUÇÃO EM PRODUÇÃO:
--    1. Execute este arquivo inteiro no Oracle (cria Java + .NET schema + seed)
--    2. NÃO execute `dotnet ef database update` — as tabelas .NET já existem.
--       Em vez disso, marque a migration como aplicada manualmente:
--         INSERT INTO "__EFMigrationsHistory" VALUES ('<migration_id>', '8.0.x');
--       Ou use `dotnet ef database update` APENAS em banco limpo (sem este script).
--    3. Suba a Java API  (ddl-auto=validate confirma schema Java)
--    4. Suba a .NET API  (DataSeeder verifica Any() e pula se zonas já existem)
--
--  Felipe Ferrete · RM 562999 · FIAP ADS Global Solution 2026/1
-- =============================================================================


-- =============================================================================
--  LIMPEZA OPCIONAL
--  Descomentar APENAS em desenvolvimento local para recriar o schema do zero.
--  NUNCA usar em produção.
-- =============================================================================
/*
BEGIN
  -- Tabelas .NET (ordem: filho antes do pai)
  FOR t IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN ('ALERTA_HISTORICO', 'ZONA_REFERENCIA_NET')
  ) LOOP
    EXECUTE IMMEDIATE
      'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;

  -- Tabelas Java (ordem: filho antes do pai)
  FOR t IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN (
      'LOG_CONSULTA', 'RECOMENDACAO', 'SCORE_DIARIO',
      'LEITURA_SATELITE', 'ZONA_CIDADE', 'USUARIO'
    )
  ) LOOP
    EXECUTE IMMEDIATE
      'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;

  -- Sequences Java
  FOR s IN (
    SELECT sequence_name FROM user_sequences
    WHERE sequence_name IN (
      'SEQ_USUARIO', 'SEQ_ZONA', 'SEQ_SCORE', 'SEQ_RECOMENDACAO', 'SEQ_LOG'
    )
  ) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;

  -- Sequences .NET (HiLo)
  FOR s IN (
    SELECT sequence_name FROM user_sequences
    WHERE sequence_name IN ('SEQ_ZONA_REFERENCIA', 'SEQ_ALERTA_HISTORICO')
  ) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;
END;
/
*/


-- =============================================================================
--  SEÇÃO 1 — SEQUENCES (Java API)
--  allocationSize = 1 no @SequenceGenerator JPA (sem cache de bloco).
-- =============================================================================

CREATE SEQUENCE seq_usuario
  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- seq_zona alimenta zona_cidade.id_zona
CREATE SEQUENCE seq_zona
  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- seq_score alimenta score_diario.id_score
-- Usado pelo JPA (ScoreService) e pela procedure calcular_score_zona.
CREATE SEQUENCE seq_score
  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE seq_recomendacao
  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- seq_log alimenta log_consulta.id_log
-- Usado pelo trigger trg_log_score_consulta e pelo LogConsultaRepository.
CREATE SEQUENCE seq_log
  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;


-- =============================================================================
--  SEÇÃO 2 — SEQUENCES (.NET API)
--  HiLo pattern: EF Core reserva blocos de 10 IDs por round-trip.
--  INCREMENT BY 10 é obrigatório — não alterar.
-- =============================================================================

CREATE SEQUENCE SEQ_ZONA_REFERENCIA
  START WITH 1 INCREMENT BY 10 NOCACHE NOCYCLE;

CREATE SEQUENCE SEQ_ALERTA_HISTORICO
  START WITH 1 INCREMENT BY 10 NOCACHE NOCYCLE;


-- =============================================================================
--  SEÇÃO 3 — TABELAS (Java API)
--  Ordem respeita dependências de FK.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  3.1  USUARIO
--  @Entity @Table("usuario") extends EntidadeAuditavel
--  dt_criacao: @CreatedDate (Spring Auditing) → TIMESTAMP
--              DEFAULT garante valor em inserts nativos (sem Spring).
-- -----------------------------------------------------------------------------
CREATE TABLE usuario (
  id_usuario        NUMBER
    CONSTRAINT pk_usuario PRIMARY KEY,
  nome              VARCHAR2(150)  NOT NULL,
  email             VARCHAR2(200)  NOT NULL
    CONSTRAINT uq_usuario_email UNIQUE,
  hash_senha        VARCHAR2(255)  NOT NULL,
  faz_exercicio     NUMBER(1)      DEFAULT 0  NOT NULL,
  tem_crianca       NUMBER(1)      DEFAULT 0  NOT NULL,
  tem_problema_resp NUMBER(1)      DEFAULT 0  NOT NULL,
  role              VARCHAR2(20)   DEFAULT 'USER'  NOT NULL,
  ativo             NUMBER(1)      DEFAULT 1  NOT NULL,
  dt_criacao        TIMESTAMP      DEFAULT SYSTIMESTAMP  NOT NULL,
  CONSTRAINT chk_faz_exerc   CHECK (faz_exercicio     IN (0, 1)),
  CONSTRAINT chk_tem_crianca CHECK (tem_crianca        IN (0, 1)),
  CONSTRAINT chk_tem_resp    CHECK (tem_problema_resp  IN (0, 1)),
  CONSTRAINT chk_role        CHECK (role               IN ('USER', 'ADMIN')),
  CONSTRAINT chk_ativo_usr   CHECK (ativo              IN (0, 1))
);

ALTER TABLE usuario MODIFY id_usuario DEFAULT seq_usuario.NEXTVAL;


-- -----------------------------------------------------------------------------
--  3.2  ZONA_CIDADE
--  @Entity @Table("zona_cidade") — não estende EntidadeAuditavel.
--  lat/lon mapeados via @Embedded Coordenada (NUMBER(9,6)).
-- -----------------------------------------------------------------------------
CREATE TABLE zona_cidade (
  id_zona    NUMBER        CONSTRAINT pk_zona PRIMARY KEY,
  nome       VARCHAR2(100) NOT NULL,
  municipio  VARCHAR2(100) DEFAULT 'São Paulo',
  lat        NUMBER(9,6),
  lon        NUMBER(9,6),
  ativo      NUMBER(1)     DEFAULT 1  NOT NULL,
  CONSTRAINT chk_ativo_zona CHECK (ativo IN (0, 1)),
  CONSTRAINT chk_lat        CHECK (lat  BETWEEN -90  AND  90),
  CONSTRAINT chk_lon        CHECK (lon  BETWEEN -180 AND 180)
);

ALTER TABLE zona_cidade MODIFY id_zona DEFAULT seq_zona.NEXTVAL;


-- -----------------------------------------------------------------------------
--  3.3  LEITURA_SATELITE
--  @Entity @Table("leitura_satelite") com @EmbeddedId (chave composta).
--
--  PK COMPOSTA: (id_zona, tipo_dado, dt_captura)
--    Atende rubrica "Modelagem Avançada > chave composta".
--
--  Enums armazenados como STRING:
--    tipo_dado → TipoDado : NO2 | TEMP_SUPERFICIE | UV
--    satelite  → TipoSatelite: SENTINEL_5P | ECOSTRESS | OMI | OPEN_METEO
-- -----------------------------------------------------------------------------
CREATE TABLE leitura_satelite (
  id_zona     NUMBER       NOT NULL,
  tipo_dado   VARCHAR2(30) NOT NULL,
  dt_captura  TIMESTAMP    NOT NULL,
  satelite    VARCHAR2(50),
  valor       NUMBER(10,4) NOT NULL,
  unidade     VARCHAR2(20),
  dt_ingestao TIMESTAMP    DEFAULT SYSTIMESTAMP,
  CONSTRAINT pk_leitura PRIMARY KEY (id_zona, tipo_dado, dt_captura),
  CONSTRAINT fk_leitura_zona FOREIGN KEY (id_zona)
    REFERENCES zona_cidade(id_zona),
  CONSTRAINT chk_tipo_dado CHECK (
    tipo_dado IN ('NO2', 'TEMP_SUPERFICIE', 'UV')
  ),
  CONSTRAINT chk_satelite CHECK (
    satelite IN ('SENTINEL_5P', 'ECOSTRESS', 'OMI', 'OPEN_METEO')
  )
);


-- -----------------------------------------------------------------------------
--  3.4  SCORE_DIARIO
--  @Entity @Table("score_diario") extends EntidadeAuditavel.
--  Inserido via JPA (ScoreService) OU via procedure calcular_score_zona.
--  dt_criacao DEFAULT garante preenchimento quando inserido pela procedure.
--
--  classificacao → ClassificacaoScore: BOM | MODERADO | RUIM | CRITICO
--  Algoritmo: 60% qualidade do ar (NO₂) + 40% temperatura superfície.
-- -----------------------------------------------------------------------------
CREATE TABLE score_diario (
  id_score      NUMBER       CONSTRAINT pk_score PRIMARY KEY,
  id_zona       NUMBER       NOT NULL,
  dt_score      DATE         NOT NULL,
  valor_score   NUMBER(5,2)  NOT NULL,
  classificacao VARCHAR2(15) NOT NULL,
  no2_valor     NUMBER(8,4),
  temp_valor    NUMBER(6,2),
  dt_criacao    TIMESTAMP    DEFAULT SYSTIMESTAMP  NOT NULL,
  CONSTRAINT fk_score_zona FOREIGN KEY (id_zona)
    REFERENCES zona_cidade(id_zona),
  CONSTRAINT chk_score_val CHECK (valor_score BETWEEN 0 AND 100),
  CONSTRAINT chk_classif   CHECK (
    classificacao IN ('BOM', 'MODERADO', 'RUIM', 'CRITICO')
  )
);

ALTER TABLE score_diario MODIFY id_score DEFAULT seq_score.NEXTVAL;


-- -----------------------------------------------------------------------------
--  3.5  RECOMENDACAO
--  @Entity @Table("recomendacao") extends EntidadeAuditavel.
--  Inserida via JPA (RecomendacaoService) OU via procedure registrar_recomendacao.
--  dt_entrega: LocalDateTime → TIMESTAMP (campo próprio da entidade).
-- -----------------------------------------------------------------------------
CREATE TABLE recomendacao (
  id_rec      NUMBER         CONSTRAINT pk_recomendacao PRIMARY KEY,
  id_score    NUMBER         NOT NULL,
  id_usuario  NUMBER         NOT NULL,
  texto       VARCHAR2(1000) NOT NULL,
  icone       VARCHAR2(30),
  dt_entrega  TIMESTAMP      DEFAULT SYSTIMESTAMP,
  dt_criacao  TIMESTAMP      DEFAULT SYSTIMESTAMP  NOT NULL,
  CONSTRAINT fk_rec_score   FOREIGN KEY (id_score)
    REFERENCES score_diario(id_score),
  CONSTRAINT fk_rec_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario(id_usuario)
);

ALTER TABLE recomendacao MODIFY id_rec DEFAULT seq_recomendacao.NEXTVAL;


-- -----------------------------------------------------------------------------
--  3.6  LOG_CONSULTA
--  @Entity @Table("log_consulta") — não estende EntidadeAuditavel.
--  id_usuario e id_zona são nullable (consultas públicas não autenticadas).
--  Populada automaticamente pelo trigger trg_log_score_consulta e
--  manualmente pelo LogConsultaRepository.
-- -----------------------------------------------------------------------------
CREATE TABLE log_consulta (
  id_log      NUMBER        CONSTRAINT pk_log PRIMARY KEY,
  id_usuario  NUMBER,
  id_zona     NUMBER,
  endpoint    VARCHAR2(200),
  ip_origem   VARCHAR2(45),
  dt_consulta TIMESTAMP     DEFAULT SYSTIMESTAMP,
  CONSTRAINT fk_log_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario(id_usuario),
  CONSTRAINT fk_log_zona FOREIGN KEY (id_zona)
    REFERENCES zona_cidade(id_zona)
);

ALTER TABLE log_consulta MODIFY id_log DEFAULT seq_log.NEXTVAL;


-- =============================================================================
--  SEÇÃO 4 — TABELAS (.NET API)
--  Criadas aqui para deploy standalone.
--  Em produção, `dotnet ef database update` faz o mesmo via migration
--  InitialCreate — idempotente se as tabelas já existirem.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  4.1  ZONA_REFERENCIA_NET
--  Espelho local das zonas de SP gerenciado pelo .NET API.
--  Populada pelo DataSeeder.cs com Random(562999) — mesmo seed do Java.
--  SEM FK para zona_cidade: cada API mantém sua própria integridade referencial.
-- -----------------------------------------------------------------------------
CREATE TABLE ZONA_REFERENCIA_NET (
  ID_ZONA   NUMBER(10)     NOT NULL,
  NOME      NVARCHAR2(100) NOT NULL,
  MUNICIPIO NVARCHAR2(100) NOT NULL,
  CONSTRAINT PK_ZONA_REFERENCIA_NET PRIMARY KEY (ID_ZONA)
);


-- -----------------------------------------------------------------------------
--  4.2  ALERTA_HISTORICO
--  Histórico de alertas — domínio exclusivo do .NET API.
--  NIVEL_ALERTA: BOM | MODERADO | RUIM | CRITICO
--    (espelha ClassificacaoScore do Java — mesma escala, sem FK)
--  SCORE_REGISTRADO : 0.00 – 100.00
--  NO2_REGISTRADO   : ppb
--  CONFIRMADO       : 0 = pendente · 1 = confirmado
-- -----------------------------------------------------------------------------
CREATE TABLE ALERTA_HISTORICO (
  ID_ALERTA          NUMBER(10)      NOT NULL,
  ID_ZONA            NUMBER(10)      NOT NULL,
  NIVEL_ALERTA       NVARCHAR2(15)   NOT NULL,
  SCORE_REGISTRADO   NUMBER(5,2)     NOT NULL,
  NO2_REGISTRADO     NUMBER(8,4)     NOT NULL,
  TEXTO_RECOMENDACAO NVARCHAR2(1000),          -- nullable: N-08 nao usa .IsRequired()
  DT_ALERTA          DATE            NOT NULL,
  CONFIRMADO         NUMBER(1)       NOT NULL,
  CONSTRAINT PK_ALERTA_HISTORICO
    PRIMARY KEY (ID_ALERTA),
  CONSTRAINT FK_ALERTA_HISTORICO_ZONA
    FOREIGN KEY (ID_ZONA)
    REFERENCES ZONA_REFERENCIA_NET (ID_ZONA),
    -- sem ON DELETE = RESTRICT por padrao no Oracle (ORA-02292 ao tentar deletar zona com alertas)
  CONSTRAINT chk_nivel_alerta CHECK (
    NIVEL_ALERTA IN ('ATENCAO', 'ALERTA', 'EMERGENCIA')
  )
);


-- =============================================================================
--  SEÇÃO 5 — INDEXES (Java API)
-- =============================================================================

-- Score mais recente por zona
-- ScoreDiarioRepository.findFirstByZonaIdOrderByDtScoreDesc
CREATE INDEX idx_score_zona_dt
  ON score_diario (id_zona, dt_score DESC);

-- Histórico dos últimos N dias por zona
-- ScoreDiarioRepository.findByZonaIdAndDtScoreAfterOrderByDtScoreDesc
CREATE INDEX idx_score_zona_hist
  ON score_diario (id_zona, dt_score);

-- Últimas leituras por zona e tipo
-- LeituraSateliteRepository.findUltimasPorZonaETipo
CREATE INDEX idx_leitura_zona_tipo_dt
  ON leitura_satelite (id_zona, tipo_dado, dt_captura DESC);

-- Recomendações por score + usuário
-- RecomendacaoRepository.findByScoreIdAndUsuarioId
CREATE INDEX idx_rec_score_usr
  ON recomendacao (id_score, id_usuario);

-- Auditoria por usuário
CREATE INDEX idx_log_usuario
  ON log_consulta (id_usuario);

-- Auditoria por zona e data
CREATE INDEX idx_log_zona_dt
  ON log_consulta (id_zona, dt_consulta DESC);


-- =============================================================================
--  SEÇÃO 6 — INDEXES (.NET API)
-- =============================================================================

-- Queries de estatísticas por zona e janela temporal
-- AlertaRepository.GetEstatisticasAsync, GetTendenciaAsync
CREATE INDEX IX_ALERTA_ZONA_DT
  ON ALERTA_HISTORICO (ID_ZONA, DT_ALERTA);


-- =============================================================================
--  SEÇÃO 7 — TRIGGERS (Java API)
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Trigger 1: trg_log_score_consulta
--  Registra automaticamente no LOG_CONSULTA cada score calculado pelo scheduler.
--  Dispara APÓS cada INSERT em score_diario.
--  Falha no log não aborta a transação principal (EXCEPTION → NULL).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_log_score_consulta
  AFTER INSERT ON score_diario
  FOR EACH ROW
BEGIN
  INSERT INTO log_consulta (id_log, id_zona, endpoint, dt_consulta)
  VALUES (
    seq_log.NEXTVAL,
    :NEW.id_zona,
    'SCHEDULER/calcular_score_zona',
    SYSTIMESTAMP
  );
EXCEPTION
  WHEN OTHERS THEN NULL;
END trg_log_score_consulta;
/


-- -----------------------------------------------------------------------------
--  Trigger 2: trg_valida_score
--  Guarda extra além do CHECK CONSTRAINT — cobre inserts via procedure que
--  bypassam validação JPA. Dispara ANTES de INSERT ou UPDATE em score_diario.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_valida_score
  BEFORE INSERT OR UPDATE ON score_diario
  FOR EACH ROW
BEGIN
  IF :NEW.valor_score < 0 OR :NEW.valor_score > 100 THEN
    RAISE_APPLICATION_ERROR(
      -20001,
      'Score fora do range 0-100: ' || TO_CHAR(:NEW.valor_score)
    );
  END IF;

  IF :NEW.classificacao NOT IN ('BOM', 'MODERADO', 'RUIM', 'CRITICO') THEN
    RAISE_APPLICATION_ERROR(
      -20002,
      'Classificacao invalida: ' || :NEW.classificacao
    );
  END IF;
END trg_valida_score;
/


-- =============================================================================
--  SEÇÃO 8 — PROCEDURES PL/SQL (Java API)
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Procedure 1: calcular_score_zona
--
--  Chamada pelo IngestaoOrbitalScheduler (Java) via StoredProcedureQuery JPA.
--
--  ALGORITMO (espelho exato de ScoreService.java — fonte única de verdade):
--    scoreNo2  = max(0, 1 − no2_ppb / 50.0)           NO2: 0 ppb = 1.0, 50 ppb = 0.0
--    scoreTemp = max(0, 1 − max(0, (tempC − 30) / 20)) Temp: ≤30°C = 1.0, ≥50°C = 0.0
--    score     = round((scoreNo2 × 0.60 + scoreTemp × 0.40) × 100, 1)
--
--  Classificação: ≥80 BOM · ≥60 MODERADO · ≥40 RUIM · <40 CRITICO
--  Após INSERT: trg_log_score_consulta registra no LOG_CONSULTA automaticamente.
-- -----------------------------------------------------------------------------
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
  WHERE id_zona   = p_zona_id
    AND tipo_dado = 'NO2'
  ORDER BY dt_captura DESC
  FETCH FIRST 1 ROWS ONLY;

  SELECT valor INTO v_temp
  FROM leitura_satelite
  WHERE id_zona   = p_zona_id
    AND tipo_dado = 'TEMP_SUPERFICIE'
  ORDER BY dt_captura DESC
  FETCH FIRST 1 ROWS ONLY;

  v_score_no2  := GREATEST(0, 1 - (v_no2  / 50));
  v_score_temp := GREATEST(0, 1 - GREATEST(0, (v_temp - 30) / 20));
  v_score      := ROUND((v_score_no2 * 0.60 + v_score_temp * 0.40) * 100, 1);

  SELECT CASE
    WHEN v_score >= 80 THEN 'BOM'
    WHEN v_score >= 60 THEN 'MODERADO'
    WHEN v_score >= 40 THEN 'RUIM'
    ELSE                    'CRITICO'
  END INTO v_class FROM DUAL;

  INSERT INTO score_diario
    (id_score, id_zona, dt_score, valor_score, classificacao, no2_valor, temp_valor)
  VALUES
    (seq_score.NEXTVAL, p_zona_id, TRUNC(SYSDATE), v_score, v_class, v_no2, v_temp);

  COMMIT;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE(
      'calcular_score_zona: sem leituras para zona ' || TO_CHAR(p_zona_id)
    );
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END calcular_score_zona;
/


-- -----------------------------------------------------------------------------
--  Procedure 2: registrar_recomendacao
--
--  Chamada pelo RecomendacaoService (Java) via StoredProcedureQuery JPA.
--  dt_criacao e dt_entrega omitidos → DEFAULT SYSTIMESTAMP do Oracle.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE registrar_recomendacao (
  p_score_id   IN NUMBER,
  p_usuario_id IN NUMBER,
  p_texto      IN VARCHAR2,
  p_icone      IN VARCHAR2
) AS
BEGIN
  INSERT INTO recomendacao (id_rec, id_score, id_usuario, texto, icone)
  VALUES (seq_recomendacao.NEXTVAL, p_score_id, p_usuario_id, p_texto, p_icone);

  COMMIT;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END registrar_recomendacao;
/


-- =============================================================================
--  SEÇÃO 9 — SEED DATA (Java API)
--  5 zonas metropolitanas de SP com coordenadas GPS reais.
--  Usadas pelo IngestaoOrbitalScheduler (Sentinel-5P / ECOSTRESS / Open-Meteo).
-- =============================================================================

INSERT INTO zona_cidade (id_zona, nome, municipio, lat, lon, ativo)
VALUES (seq_zona.NEXTVAL, 'Centro',     'São Paulo', -23.5505, -46.6333, 1);

INSERT INTO zona_cidade (id_zona, nome, municipio, lat, lon, ativo)
VALUES (seq_zona.NEXTVAL, 'Zona Leste', 'São Paulo', -23.5474, -46.4767, 1);

INSERT INTO zona_cidade (id_zona, nome, municipio, lat, lon, ativo)
VALUES (seq_zona.NEXTVAL, 'Zona Sul',   'São Paulo', -23.6821, -46.6242, 1);

INSERT INTO zona_cidade (id_zona, nome, municipio, lat, lon, ativo)
VALUES (seq_zona.NEXTVAL, 'Zona Norte', 'São Paulo', -23.4891, -46.6262, 1);

INSERT INTO zona_cidade (id_zona, nome, municipio, lat, lon, ativo)
VALUES (seq_zona.NEXTVAL, 'Zona Oeste', 'São Paulo', -23.5607, -46.7182, 1);

-- Usuário admin para Swagger e testes de integração.
-- Senha: Admin@2026! (BCrypt strength=12) — TROCAR antes de deploy público.
INSERT INTO usuario (
  id_usuario, nome, email, hash_senha,
  role, faz_exercicio, tem_crianca, tem_problema_resp, ativo
)
VALUES (
  seq_usuario.NEXTVAL,
  'Admin Pulso Urbano',
  'admin@pulsourbano.com.br',
  '$2a$12$K0bStl1c6I7mVHfIq.VHIeRJHs3jY4J3RjNblM5X1qe1Kq.2HWWSO',
  'ADMIN', 0, 0, 0, 1
);

-- Usuário de demonstração (exercitante com criança).
INSERT INTO usuario (
  id_usuario, nome, email, hash_senha,
  role, faz_exercicio, tem_crianca, tem_problema_resp, ativo
)
VALUES (
  seq_usuario.NEXTVAL,
  'Felipe Demo',
  'demo@pulsourbano.com.br',
  '$2a$12$K0bStl1c6I7mVHfIq.VHIeRJHs3jY4J3RjNblM5X1qe1Kq.2HWWSO',
  'USER', 1, 1, 0, 1
);

COMMIT;


-- =============================================================================
--  SEÇÃO 10 — SEED DATA (.NET API)
--  ZONA_REFERENCIA_NET espelha as mesmas 5 zonas do Java com IDs idênticos.
--  IDs fixos (1-5) para garantir consistência com o DataSeeder.cs
--  (Random seed 562999 — mesmo seed dos dois lados).
--  Em produção o DataSeeder popula isso automaticamente na inicialização.
-- =============================================================================

INSERT INTO ZONA_REFERENCIA_NET (ID_ZONA, NOME, MUNICIPIO)
VALUES (1, 'Centro',     'São Paulo');

INSERT INTO ZONA_REFERENCIA_NET (ID_ZONA, NOME, MUNICIPIO)
VALUES (2, 'Zona Leste', 'São Paulo');

INSERT INTO ZONA_REFERENCIA_NET (ID_ZONA, NOME, MUNICIPIO)
VALUES (3, 'Zona Sul',   'São Paulo');

INSERT INTO ZONA_REFERENCIA_NET (ID_ZONA, NOME, MUNICIPIO)
VALUES (4, 'Zona Norte', 'São Paulo');

INSERT INTO ZONA_REFERENCIA_NET (ID_ZONA, NOME, MUNICIPIO)
VALUES (5, 'Zona Oeste', 'São Paulo');

COMMIT;


-- =============================================================================
--  SEÇÃO 11 — VERIFICAÇÃO FINAL
-- =============================================================================

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== PULSO URBANO — Schema unificado criado com sucesso ===');
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('-- Java API --');
  FOR t IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN (
      'USUARIO', 'ZONA_CIDADE', 'LEITURA_SATELITE',
      'SCORE_DIARIO', 'RECOMENDACAO', 'LOG_CONSULTA'
    )
    ORDER BY table_name
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  [OK] Tabela: ' || t.table_name);
  END LOOP;

  FOR s IN (
    SELECT sequence_name FROM user_sequences
    WHERE sequence_name IN (
      'SEQ_USUARIO', 'SEQ_ZONA', 'SEQ_SCORE', 'SEQ_RECOMENDACAO', 'SEQ_LOG'
    )
    ORDER BY sequence_name
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  [OK] Sequence: ' || s.sequence_name);
  END LOOP;

  FOR p IN (
    SELECT object_name, object_type FROM user_objects
    WHERE object_type IN ('PROCEDURE', 'TRIGGER')
      AND object_name IN (
        'CALCULAR_SCORE_ZONA', 'REGISTRAR_RECOMENDACAO',
        'TRG_LOG_SCORE_CONSULTA', 'TRG_VALIDA_SCORE'
      )
    ORDER BY object_type, object_name
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  [OK] ' || p.object_type || ': ' || p.object_name);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('-- .NET API --');
  FOR t IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN ('ZONA_REFERENCIA_NET', 'ALERTA_HISTORICO')
    ORDER BY table_name
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  [OK] Tabela: ' || t.table_name);
  END LOOP;

  FOR s IN (
    SELECT sequence_name FROM user_sequences
    WHERE sequence_name IN ('SEQ_ZONA_REFERENCIA', 'SEQ_ALERTA_HISTORICO')
    ORDER BY sequence_name
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  [OK] Sequence (HiLo): ' || s.sequence_name);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== Pronto. Suba as APIs na ordem da documentação do cabeçalho. ===');
END;
/
