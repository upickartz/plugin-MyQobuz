# change  unique constraint tag
CREATE TABLE tag_copy ( id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL, 
                        group_name TEXT DEFAULT '#no_group#' NOT NULL,
                        UNIQUE(name,group_name));
INSERT INTO tag_copy SELECT * FROM tag;
DROP TABLE tag;
ALTER TABLE tag_copy RENAME TO tag;
# change album
ALTER TABLE album add column  year INTEGER DEFAULT NULL ;
ALTER TABLE album add column  label TEXT DEFAULT NULL ;
ALTER TABLE album add column  goodies_url TEXT DEFAULT NULL ;
CREATE INDEX index_year ON album (year);
CREATE INDEX index_label ON album (label);
# only for main-artist
CREATE TABLE IF NOT EXISTS artist_album (artist TEXT,album TEXT,PRIMARY KEY (artist,album));
# change track
ALTER TABLE track add column  goodies_url TEXT DEFAULT NULL;





