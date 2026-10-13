-- Creates one database and one login role per service.
-- Each role owns only its own database, and PUBLIC cannot connect to any of them,
-- so a service physically cannot read another service's data.
-- LOCAL DEVELOPMENT PASSWORDS ONLY.

CREATE ROLE auth_svc         LOGIN PASSWORD 'auth_local_pw';
CREATE ROLE product_svc      LOGIN PASSWORD 'product_local_pw';
CREATE ROLE inventory_svc    LOGIN PASSWORD 'inventory_local_pw';
CREATE ROLE saga_svc         LOGIN PASSWORD 'saga_local_pw';
CREATE ROLE payment_svc      LOGIN PASSWORD 'payment_local_pw';
CREATE ROLE notification_svc LOGIN PASSWORD 'notification_local_pw';

CREATE DATABASE auth_db         OWNER auth_svc;
CREATE DATABASE product_db      OWNER product_svc;
CREATE DATABASE inventory_db    OWNER inventory_svc;
CREATE DATABASE saga_db         OWNER saga_svc;
CREATE DATABASE payment_db      OWNER payment_svc;
CREATE DATABASE notification_db OWNER notification_svc;

REVOKE CONNECT ON DATABASE auth_db         FROM PUBLIC;
REVOKE CONNECT ON DATABASE product_db      FROM PUBLIC;
REVOKE CONNECT ON DATABASE inventory_db    FROM PUBLIC;
REVOKE CONNECT ON DATABASE saga_db         FROM PUBLIC;
REVOKE CONNECT ON DATABASE payment_db      FROM PUBLIC;
REVOKE CONNECT ON DATABASE notification_db FROM PUBLIC;

-- Prisma Migrate needs to create a temporary "shadow" database during `migrate dev`.
ALTER ROLE auth_svc CREATEDB;
