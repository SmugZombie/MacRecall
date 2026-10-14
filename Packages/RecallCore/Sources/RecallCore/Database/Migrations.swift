import Foundation

/// Ordered, append-only schema migrations. Never edit a shipped migration;
/// add a new one instead.
enum Migrations {
    static let all: [(version: Int, sql: String)] = [
        (1, v1),
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let current = try db.scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        for migration in all where migration.version > current {
            try db.transaction {
                try db.execute(migration.sql)
                try db.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", [migration.version, Date()])
            }
        }
    }

    static let v1 = """
    CREATE TABLE applications (
        id INTEGER PRIMARY KEY,
        bundle_identifier TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        first_seen REAL NOT NULL,
        last_seen REAL NOT NULL
    );

    CREATE TABLE windows (
        id INTEGER PRIMARY KEY,
        application_id INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
        system_window_id INTEGER NOT NULL DEFAULT 0,
        title TEXT NOT NULL DEFAULT '',
        first_seen REAL NOT NULL,
        last_seen REAL NOT NULL,
        UNIQUE(application_id, system_window_id, title)
    );

    CREATE TABLE projects (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        description TEXT NOT NULL DEFAULT '',
        identification_rules_json TEXT NOT NULL DEFAULT '{}',
        created_at REAL NOT NULL
    );

    CREATE TABLE sessions (
        id INTEGER PRIMARY KEY,
        started_at REAL NOT NULL,
        ended_at REAL NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        title_source TEXT NOT NULL DEFAULT 'deterministic',
        summary TEXT NOT NULL DEFAULT '',
        project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
        project_source TEXT NOT NULL DEFAULT 'none',
        classification_confidence REAL,
        active_seconds REAL NOT NULL DEFAULT 0,
        user_locked INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX sessions_started ON sessions(started_at);

    CREATE TABLE captures (
        id INTEGER PRIMARY KEY,
        application_id INTEGER NOT NULL REFERENCES applications(id),
        window_id INTEGER REFERENCES windows(id),
        captured_at REAL NOT NULL,
        last_seen_at REAL NOT NULL,
        timezone TEXT NOT NULL,
        pid INTEGER NOT NULL DEFAULT 0,
        image_path TEXT NOT NULL,
        thumbnail_path TEXT NOT NULL,
        image_hash TEXT NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        ocr_text TEXT NOT NULL DEFAULT '',
        ocr_confidence REAL,
        ocr_status TEXT NOT NULL DEFAULT 'pending',
        ai_status TEXT NOT NULL DEFAULT 'pending',
        ai_description TEXT NOT NULL DEFAULT '',
        ai_json TEXT,
        redacted INTEGER NOT NULL DEFAULT 0,
        project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
        activity_session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}'
    );
    CREATE INDEX captures_time ON captures(captured_at);
    CREATE INDEX captures_session ON captures(activity_session_id);
    CREATE INDEX captures_app ON captures(application_id, captured_at);
    CREATE INDEX captures_project ON captures(project_id);

    CREATE TABLE activity_events (
        id INTEGER PRIMARY KEY,
        timestamp REAL NOT NULL,
        event_type TEXT NOT NULL,
        application_id INTEGER REFERENCES applications(id) ON DELETE SET NULL,
        window_id INTEGER REFERENCES windows(id) ON DELETE SET NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}'
    );
    CREATE INDEX events_time ON activity_events(timestamp);

    CREATE TABLE ai_jobs (
        id INTEGER PRIMARY KEY,
        job_type TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at REAL NOT NULL,
        next_attempt_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL
    );
    -- At most one live job per (type, entity): enqueueing again is a no-op.
    CREATE UNIQUE INDEX ai_jobs_live ON ai_jobs(job_type, entity_type, entity_id)
        WHERE status IN ('pending', 'running');
    CREATE INDEX ai_jobs_ready ON ai_jobs(status, next_attempt_at, priority);

    CREATE TABLE embeddings (
        id INTEGER PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id INTEGER NOT NULL,
        model TEXT NOT NULL,
        model_version TEXT NOT NULL DEFAULT '',
        dimensions INTEGER NOT NULL,
        vector_data BLOB NOT NULL,
        entity_time REAL NOT NULL,
        created_at REAL NOT NULL,
        UNIQUE(entity_type, entity_id, model)
    );
    CREATE INDEX embeddings_scan ON embeddings(model, entity_type, entity_time);

    CREATE TABLE daily_summaries (
        id INTEGER PRIMARY KEY,
        local_date TEXT NOT NULL,
        timezone TEXT NOT NULL,
        summary TEXT NOT NULL,
        generated_at REAL NOT NULL,
        UNIQUE(local_date, timezone)
    );

    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    -- Full-text indexes. rowid mirrors the source row id.
    CREATE VIRTUAL TABLE capture_fts USING fts5(
        app_name, window_title, ocr_text, ai_description, project,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE VIRTUAL TABLE session_fts USING fts5(
        title, summary, project,
        tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER captures_fts_insert AFTER INSERT ON captures BEGIN
        INSERT INTO capture_fts(rowid, app_name, window_title, ocr_text, ai_description, project) VALUES (
            new.id,
            (SELECT name FROM applications WHERE id = new.application_id),
            COALESCE((SELECT title FROM windows WHERE id = new.window_id), ''),
            new.ocr_text, new.ai_description,
            COALESCE((SELECT name FROM projects WHERE id = new.project_id), '')
        );
    END;
    CREATE TRIGGER captures_fts_update AFTER UPDATE OF ocr_text, ai_description, window_id, project_id ON captures BEGIN
        DELETE FROM capture_fts WHERE rowid = old.id;
        INSERT INTO capture_fts(rowid, app_name, window_title, ocr_text, ai_description, project) VALUES (
            new.id,
            (SELECT name FROM applications WHERE id = new.application_id),
            COALESCE((SELECT title FROM windows WHERE id = new.window_id), ''),
            new.ocr_text, new.ai_description,
            COALESCE((SELECT name FROM projects WHERE id = new.project_id), '')
        );
    END;
    CREATE TRIGGER captures_fts_delete AFTER DELETE ON captures BEGIN
        DELETE FROM capture_fts WHERE rowid = old.id;
        DELETE FROM embeddings WHERE entity_type = 'capture' AND entity_id = old.id;
        DELETE FROM ai_jobs WHERE entity_type = 'capture' AND entity_id = old.id;
    END;

    CREATE TRIGGER sessions_fts_insert AFTER INSERT ON sessions BEGIN
        INSERT INTO session_fts(rowid, title, summary, project) VALUES (
            new.id, new.title, new.summary,
            COALESCE((SELECT name FROM projects WHERE id = new.project_id), '')
        );
    END;
    CREATE TRIGGER sessions_fts_update AFTER UPDATE OF title, summary, project_id ON sessions BEGIN
        DELETE FROM session_fts WHERE rowid = old.id;
        INSERT INTO session_fts(rowid, title, summary, project) VALUES (
            new.id, new.title, new.summary,
            COALESCE((SELECT name FROM projects WHERE id = new.project_id), '')
        );
    END;
    CREATE TRIGGER sessions_fts_delete AFTER DELETE ON sessions BEGIN
        DELETE FROM session_fts WHERE rowid = old.id;
        DELETE FROM embeddings WHERE entity_type = 'session' AND entity_id = old.id;
        DELETE FROM ai_jobs WHERE entity_type = 'session' AND entity_id = old.id;
    END;
    """
}
