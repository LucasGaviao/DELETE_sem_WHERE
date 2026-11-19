-- DDL gerado dinamicamente a partir do schema public para public
CREATE SCHEMA IF NOT EXISTS public;

CREATE TABLE public.album (
    album_id integer NOT NULL,
    title character varying(160) NOT NULL,
    artist_id integer NOT NULL,
    CONSTRAINT album_pkey PRIMARY KEY (album_id)
);

CREATE TABLE public.artist (
    artist_id integer NOT NULL,
    name character varying(120),
    CONSTRAINT artist_pkey PRIMARY KEY (artist_id)
);

CREATE TABLE public.customer (
    customer_id integer NOT NULL,
    first_name character varying(40) NOT NULL,
    last_name character varying(20) NOT NULL,
    company character varying(80),
    address character varying(70),
    city character varying(40),
    state character varying(40),
    country character varying(40),
    postal_code character varying(10),
    phone character varying(24),
    fax character varying(24),
    email character varying(60) NOT NULL,
    support_rep_id integer,
    CONSTRAINT customer_pkey PRIMARY KEY (customer_id)
);

CREATE TABLE public.employee (
    employee_id integer NOT NULL,
    last_name character varying(20) NOT NULL,
    first_name character varying(20) NOT NULL,
    title character varying(30),
    reports_to integer,
    birth_date timestamp without time zone,
    hire_date timestamp without time zone,
    address character varying(70),
    city character varying(40),
    state character varying(40),
    country character varying(40),
    postal_code character varying(10),
    phone character varying(24),
    fax character varying(24),
    email character varying(60),
    CONSTRAINT employee_pkey PRIMARY KEY (employee_id)
);

CREATE TABLE public.genre (
    genre_id integer NOT NULL,
    name character varying(120),
    CONSTRAINT genre_pkey PRIMARY KEY (genre_id)
);

CREATE TABLE public.invoice (
    invoice_id integer NOT NULL,
    customer_id integer NOT NULL,
    invoice_date timestamp without time zone NOT NULL,
    billing_address character varying(70),
    billing_city character varying(40),
    billing_state character varying(40),
    billing_country character varying(40),
    billing_postal_code character varying(10),
    total numeric(10,2) NOT NULL,
    status text NOT NULL,
    CONSTRAINT invoice_pkey PRIMARY KEY (invoice_id)
);

CREATE TABLE public.invoice_line (
    invoice_line_id integer NOT NULL,
    invoice_id integer NOT NULL,
    track_id integer NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    quantity integer NOT NULL,
    CONSTRAINT invoice_line_pkey PRIMARY KEY (invoice_line_id)
);

CREATE TABLE public.media_type (
    media_type_id integer NOT NULL,
    name character varying(120),
    CONSTRAINT media_type_pkey PRIMARY KEY (media_type_id)
);

CREATE TABLE public.playlist (
    playlist_id integer NOT NULL,
    name character varying(120),
    CONSTRAINT playlist_pkey PRIMARY KEY (playlist_id)
);

CREATE TABLE public.playlist_track (
    playlist_id integer NOT NULL,
    track_id integer NOT NULL,
    CONSTRAINT playlist_track_pkey PRIMARY KEY (playlist_id, track_id)
);

CREATE TABLE public.track (
    track_id integer NOT NULL,
    name character varying(200) NOT NULL,
    album_id integer,
    media_type_id integer NOT NULL,
    genre_id integer,
    composer character varying(220),
    milliseconds integer NOT NULL,
    bytes integer,
    unit_price numeric(10,2) NOT NULL,
    CONSTRAINT track_pkey PRIMARY KEY (track_id)
);

ALTER TABLE public.album ADD CONSTRAINT album_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES public.artist (artist_id);
ALTER TABLE public.customer ADD CONSTRAINT customer_support_rep_id_fkey FOREIGN KEY (support_rep_id) REFERENCES public.employee (employee_id);
ALTER TABLE public.employee ADD CONSTRAINT employee_reports_to_fkey FOREIGN KEY (reports_to) REFERENCES public.employee (employee_id);
ALTER TABLE public.invoice ADD CONSTRAINT invoice_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer (customer_id);
ALTER TABLE public.invoice_line ADD CONSTRAINT invoice_line_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoice (invoice_id);
ALTER TABLE public.invoice_line ADD CONSTRAINT invoice_line_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.track (track_id);
ALTER TABLE public.playlist_track ADD CONSTRAINT playlist_track_playlist_id_fkey FOREIGN KEY (playlist_id) REFERENCES public.playlist (playlist_id);
ALTER TABLE public.playlist_track ADD CONSTRAINT playlist_track_track_id_fkey FOREIGN KEY (track_id) REFERENCES public.track (track_id);
ALTER TABLE public.track ADD CONSTRAINT track_album_id_fkey FOREIGN KEY (album_id) REFERENCES public.album (album_id);
ALTER TABLE public.track ADD CONSTRAINT track_genre_id_fkey FOREIGN KEY (genre_id) REFERENCES public.genre (genre_id);
ALTER TABLE public.track ADD CONSTRAINT track_media_type_id_fkey FOREIGN KEY (media_type_id) REFERENCES public.media_type (media_type_id);

