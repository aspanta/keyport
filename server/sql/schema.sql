CREATE TABLE scopes (
    id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name                    VARCHAR(64) NOT NULL,
    state                   ENUM('ACTIVE', 'LOCKED', 'DISABLED') NOT NULL DEFAULT 'ACTIVE',
    lock_on_source_mismatch BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                                      ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uq_scopes_name (name)
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;


CREATE TABLE credentials (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    scope_id     BIGINT UNSIGNED NOT NULL,
    api_key_hash BINARY(32) NOT NULL,
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uq_credentials_hash (api_key_hash),
    KEY fk_credentials_scope (scope_id),

    CONSTRAINT fk_credentials_scope
        FOREIGN KEY (scope_id)
        REFERENCES scopes (id)
        ON DELETE CASCADE
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;


CREATE TABLE sources (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    scope_id   BIGINT UNSIGNED NOT NULL,
    source     VARCHAR(49) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uq_sources_scope_source (scope_id, source),

    CONSTRAINT fk_sources_scope
        FOREIGN KEY (scope_id)
        REFERENCES scopes (id)
        ON DELETE CASCADE
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;


CREATE TABLE `keys` (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    scope_id   BIGINT UNSIGNED NOT NULL,
    keyname    VARCHAR(64) NOT NULL,
    keyvalue   TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                         ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uq_keys_scope_keyname (scope_id, keyname),

    CONSTRAINT fk_keys_scope
        FOREIGN KEY (scope_id)
        REFERENCES scopes (id)
        ON DELETE CASCADE
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;


CREATE TABLE audit (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    scope_id   BIGINT UNSIGNED DEFAULT NULL,
    source     VARCHAR(45) NOT NULL,
    method     VARCHAR(8) NOT NULL,
    keyname    VARCHAR(64) DEFAULT NULL,
    result     VARCHAR(32) NOT NULL,

    PRIMARY KEY (id),
    KEY idx_audit_created (created_at),
    KEY idx_audit_scope_created (scope_id, created_at),

    CONSTRAINT fk_audit_scope
        FOREIGN KEY (scope_id)
        REFERENCES scopes (id)
        ON DELETE CASCADE
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;

CREATE TABLE schema_migrations (
    version     VARCHAR(255) NOT NULL,
    checksum    CHAR(64) NOT NULL,
    applied_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (version)
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;
