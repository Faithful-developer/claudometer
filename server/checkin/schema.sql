-- One row per install per UTC day. No IP addresses or account data.
CREATE TABLE IF NOT EXISTS pings (
    day TEXT NOT NULL,       -- YYYY-MM-DD (UTC)
    id TEXT NOT NULL,        -- random UUID made by the app
    version TEXT NOT NULL,
    language TEXT NOT NULL,
    os TEXT NOT NULL,
    PRIMARY KEY (day, id)
);
CREATE INDEX IF NOT EXISTS pings_id ON pings (id);
