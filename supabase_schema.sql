-- ═══════════════════════════════════════════════════════════════════
-- NAKHAT EDDAR — نكهة الدار
-- Supabase Schema COMPLET — v2.0
-- Corrections: cron reset mensuel + panier persistant
-- ═══════════════════════════════════════════════════════════════════

-- Extensions requises
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_cron";   -- Supabase Pro → onglet Database > Extensions

-- ═══════════════════════════════════════
-- ENUMS
-- ═══════════════════════════════════════
CREATE TYPE order_status AS ENUM (
  'received','preparing','ready','out_for_delivery','delivered','cancelled'
);
CREATE TYPE loyalty_tier  AS ENUM ('starter','bronze','silver','gold','vip');
CREATE TYPE driver_status AS ENUM ('available','busy','offline');

-- ═══════════════════════════════════════
-- PROFILES  (étend auth.users)
-- ═══════════════════════════════════════
CREATE TABLE public.profiles (
  id                   UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name            TEXT,
  phone                TEXT,
  avatar_url           TEXT,
  preferred_lang       TEXT DEFAULT 'fr' CHECK (preferred_lang IN ('ar','fr','en')),
  -- Fidélité
  loyalty_tier         loyalty_tier DEFAULT 'starter',
  monthly_spend        NUMERIC(10,3) DEFAULT 0,   -- ← reset chaque 1er du mois
  total_spend          NUMERIC(10,3) DEFAULT 0,   -- cumulatif à vie
  last_reset           DATE DEFAULT CURRENT_DATE, -- ← horodatage du dernier reset
  -- Adresse par défaut
  default_governorate  TEXT,
  default_city         TEXT,
  default_area         TEXT,
  default_street       TEXT,
  default_house        TEXT,
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- CATÉGORIES
-- ═══════════════════════════════════════
CREATE TABLE public.categories (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name_ar     TEXT NOT NULL,
  name_fr     TEXT NOT NULL,
  name_en     TEXT NOT NULL,
  slug        TEXT UNIQUE NOT NULL,
  icon_url    TEXT,
  sort_order  INT DEFAULT 0,
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.categories (name_ar,name_fr,name_en,slug,sort_order) VALUES
  ('التوابل',         'Épices',            'Spices',           'spices',       1),
  ('الأعشاب',         'Herbes',            'Herbs',            'herbs',        2),
  ('المكسرات',        'Noix & graines',    'Nuts & Seeds',     'nuts',         3),
  ('الفواكه المجففة', 'Fruits secs',       'Dried Fruits',     'dried-fruits', 4),
  ('الزيوت',          'Huiles',            'Oils',             'oils',         5),
  ('المنتجات التقليدية','Produits traditionnels','Traditional','traditional',  6),
  ('الأغذية الصحية',  'Aliments sains',    'Healthy Foods',    'healthy',      7);

-- ═══════════════════════════════════════
-- PRODUITS
-- ═══════════════════════════════════════
CREATE TABLE public.products (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  category_id     UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  name_ar         TEXT NOT NULL,
  name_fr         TEXT NOT NULL,
  name_en         TEXT NOT NULL,
  description_ar  TEXT,
  description_fr  TEXT,
  description_en  TEXT,
  benefits_ar     TEXT,
  benefits_fr     TEXT,
  price           NUMERIC(10,3) NOT NULL,
  promo_price     NUMERIC(10,3),
  unit            TEXT DEFAULT '100g',
  stock_qty       NUMERIC(10,3) DEFAULT 0,
  stock_unit      TEXT DEFAULT 'kg',
  images          TEXT[] DEFAULT '{}',
  is_active       BOOLEAN DEFAULT TRUE,
  is_featured     BOOLEAN DEFAULT FALSE,
  is_new          BOOLEAN DEFAULT FALSE,
  sort_order      INT DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_products_category ON public.products(category_id);
CREATE INDEX idx_products_active    ON public.products(is_active);
CREATE INDEX idx_products_featured  ON public.products(is_featured);

-- ═══════════════════════════════════════
-- ZONES DE LIVRAISON  (prix modifiables par admin)
-- ═══════════════════════════════════════
CREATE TABLE public.delivery_zones (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  governorate  TEXT NOT NULL,
  city         TEXT NOT NULL,
  area         TEXT DEFAULT '',
  price        NUMERIC(10,3) NOT NULL,
  is_active    BOOLEAN DEFAULT TRUE,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.delivery_zones (governorate,city,area,price) VALUES
  ('Sousse','Sousse','Sousse Centre', 3.000),
  ('Sousse','Sousse','Khezama',       4.000),
  ('Sousse','Hammam Sousse','',       5.000),
  ('Sousse','Akouda','',              7.000),
  ('Sousse','Kantaoui','',            6.000),
  ('Sousse','Kalaa Kobra','',         8.000),
  ('Tunis','Tunis','Tunis Centre',    8.000),
  ('Sfax','Sfax','Sfax Centre',      10.000);

-- ═══════════════════════════════════════
-- COUPONS
-- ═══════════════════════════════════════
CREATE TABLE public.coupons (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code          TEXT UNIQUE NOT NULL,
  discount_pct  NUMERIC(5,2) NOT NULL CHECK (discount_pct > 0 AND discount_pct <= 100),
  min_order     NUMERIC(10,3) DEFAULT 0,
  max_uses      INT,
  current_uses  INT DEFAULT 0,
  valid_from    TIMESTAMPTZ DEFAULT NOW(),
  valid_until   TIMESTAMPTZ,
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.coupons (code,discount_pct,min_order,max_uses,valid_until) VALUES
  ('WELCOME10', 10, 0,   1000, NOW() + INTERVAL '1 year'),
  ('RAMADAN15', 15, 50,  500,  NOW() + INTERVAL '6 months'),
  ('AID20',     20, 100, 200,  NOW() + INTERVAL '3 months');

-- ═══════════════════════════════════════
-- PANIER PERSISTANT  ← CORRECTION #2
-- Lié à l'utilisateur connecté
-- Survit aux redémarrages, synchronisé entre appareils
-- Effacé après checkout (voir fonction checkout)
-- ═══════════════════════════════════════
CREATE TABLE public.cart_items (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id)  ON DELETE CASCADE,
  product_id  UUID NOT NULL REFERENCES public.products(id)  ON DELETE CASCADE,
  quantity    INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, product_id)   -- pas de doublon, on UPDATE la qté
);

CREATE INDEX idx_cart_user    ON public.cart_items(user_id);
CREATE INDEX idx_cart_product ON public.cart_items(product_id);

-- ═══════════════════════════════════════
-- COMMANDES
-- ═══════════════════════════════════════
CREATE TABLE public.orders (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID REFERENCES public.profiles(id),
  order_number      TEXT UNIQUE NOT NULL,
  status            order_status DEFAULT 'received',
  -- Montants
  subtotal          NUMERIC(10,3) NOT NULL,
  loyalty_discount  NUMERIC(10,3) DEFAULT 0,
  coupon_discount   NUMERIC(10,3) DEFAULT 0,
  delivery_fee      NUMERIC(10,3) DEFAULT 0,
  total             NUMERIC(10,3) NOT NULL,
  -- Coupon
  coupon_id         UUID REFERENCES public.coupons(id),
  coupon_code       TEXT,
  -- Adresse livraison
  delivery_zone_id  UUID REFERENCES public.delivery_zones(id),
  governorate       TEXT,
  city              TEXT,
  area              TEXT,
  street            TEXT,
  house_number      TEXT,
  customer_phone    TEXT,
  -- Cadeau (≥200 DT)
  has_gift          BOOLEAN DEFAULT FALSE,
  -- Livreur assigné
  driver_id         UUID,
  notes             TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_orders_user   ON public.orders(user_id);
CREATE INDEX idx_orders_status ON public.orders(status);
CREATE INDEX idx_orders_date   ON public.orders(created_at DESC);

-- Génération automatique du numéro de commande
CREATE OR REPLACE FUNCTION generate_order_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.order_number :=
    'ND-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' ||
    LPAD(FLOOR(RANDOM() * 100000)::TEXT, 5, '0');
  RETURN NEW;
END;$$;

CREATE TRIGGER trg_order_number
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION generate_order_number();

-- ═══════════════════════════════════════
-- ITEMS DE COMMANDE
-- ═══════════════════════════════════════
CREATE TABLE public.order_items (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id    UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id  UUID REFERENCES public.products(id),
  name_ar     TEXT NOT NULL,
  name_fr     TEXT NOT NULL,
  unit_price  NUMERIC(10,3) NOT NULL,
  quantity    INT NOT NULL,
  subtotal    NUMERIC(10,3) NOT NULL
);

CREATE INDEX idx_oitems_order ON public.order_items(order_id);

-- ═══════════════════════════════════════
-- HISTORIQUE STATUTS COMMANDE
-- ═══════════════════════════════════════
CREATE TABLE public.order_status_history (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id    UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  status      order_status NOT NULL,
  note        TEXT,
  changed_by  UUID,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- LIVREURS
-- ═══════════════════════════════════════
CREATE TABLE public.drivers (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name   TEXT NOT NULL,
  phone       TEXT NOT NULL,
  zone_ids    UUID[],
  status      driver_status DEFAULT 'available',
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- FAVORIS
-- ═══════════════════════════════════════
CREATE TABLE public.favorites (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  product_id  UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, product_id)
);

-- ═══════════════════════════════════════
-- NOTIFICATIONS
-- ═══════════════════════════════════════
CREATE TABLE public.notifications (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  title_ar    TEXT, title_fr TEXT, title_en TEXT,
  body_ar     TEXT, body_fr  TEXT, body_en  TEXT,
  type        TEXT DEFAULT 'general',
  order_id    UUID REFERENCES public.orders(id),
  is_read     BOOLEAN DEFAULT FALSE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- CHATS IA
-- ═══════════════════════════════════════
CREATE TABLE public.ai_chats (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  messages    JSONB DEFAULT '[]',
  lang        TEXT DEFAULT 'ar',
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- PROMOTIONS / BANNIÈRES
-- ═══════════════════════════════════════
CREATE TABLE public.promotions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title_ar       TEXT, title_fr TEXT, title_en TEXT,
  description_ar TEXT, description_fr TEXT,
  image_url      TEXT,
  promo_type     TEXT DEFAULT 'banner'
                 CHECK (promo_type IN ('banner','flash','seasonal','weekly')),
  discount_pct   NUMERIC(5,2),
  product_ids    UUID[],
  category_ids   UUID[],
  valid_from     TIMESTAMPTZ DEFAULT NOW(),
  valid_until    TIMESTAMPTZ,
  is_active      BOOLEAN DEFAULT TRUE,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════
-- PARAMÈTRES ADMIN
-- ═══════════════════════════════════════
CREATE TABLE public.settings (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.settings (key,value) VALUES
  ('loyalty_tiers', '{
    "starter": {"min":0,    "max":99,    "discount_pct":3},
    "bronze":  {"min":100,  "max":199,   "discount_pct":5},
    "silver":  {"min":200,  "max":399,   "discount_pct":7},
    "gold":    {"min":400,  "max":999,   "discount_pct":10},
    "vip":     {"min":1000, "max":99999, "discount_pct":15}
  }'),
  ('gift_threshold',      '200'),
  ('gift_description_ar', '"سلة هدايا حرفية (قيمة 25 دت)"'),
  ('gift_description_fr', '"Panier garni artisanal (valeur 25 DT)"'),
  ('last_monthly_reset',  'null');

-- ═══════════════════════════════════════
-- FONCTION : calcul du palier fidélité
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION compute_loyalty_tier(spend NUMERIC)
RETURNS loyalty_tier LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF    spend >= 1000 THEN RETURN 'vip';
  ELSIF spend >= 400  THEN RETURN 'gold';
  ELSIF spend >= 200  THEN RETURN 'silver';
  ELSIF spend >= 100  THEN RETURN 'bronze';
  ELSE                     RETURN 'starter';
  END IF;
END;$$;

-- ═══════════════════════════════════════
-- TRIGGER : mise à jour palier fidélité
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION update_loyalty_tier()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.loyalty_tier := compute_loyalty_tier(NEW.monthly_spend);
  NEW.updated_at   := NOW();
  RETURN NEW;
END;$$;

CREATE TRIGGER trg_loyalty_tier
  BEFORE UPDATE OF monthly_spend ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION update_loyalty_tier();

-- ═══════════════════════════════════════
-- TRIGGER : incrémente monthly_spend à la livraison
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION add_order_to_loyalty()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'delivered' AND OLD.status <> 'delivered' THEN
    UPDATE public.profiles
       SET monthly_spend = monthly_spend + NEW.total,
           total_spend   = total_spend   + NEW.total
     WHERE id = NEW.user_id;
  END IF;
  RETURN NEW;
END;$$;

CREATE TRIGGER trg_order_loyalty
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION add_order_to_loyalty();

-- ═══════════════════════════════════════
-- TRIGGER : log historique statuts
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION log_order_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO public.order_status_history(order_id, status)
    VALUES (NEW.id, NEW.status);
  END IF;
  RETURN NEW;
END;$$;

CREATE TRIGGER trg_order_status_log
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION log_order_status();

-- ═══════════════════════════════════════
-- TRIGGER : updated_at générique
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END;$$;

CREATE TRIGGER trg_cart_updated
  BEFORE UPDATE ON public.cart_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_product_updated
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_zone_updated
  BEFORE UPDATE ON public.delivery_zones
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ═══════════════════════════════════════
-- CRON JOB : RESET MENSUEL ← CORRECTION #1
-- Tourne le 1er de chaque mois à minuit
-- Remet monthly_spend à 0 pour TOUS les utilisateurs
-- Recalcule le palier → tous reviennent à 'starter'
-- Enregistre last_reset et met à jour settings
-- ═══════════════════════════════════════
SELECT cron.schedule(
  'monthly-loyalty-reset',   -- nom du job (unique)
  '0 0 1 * *',               -- cron: minuit le 1er de chaque mois
  $$
    -- 1. Reset de chaque profil ayant dépensé quelque chose
    UPDATE public.profiles
       SET monthly_spend = 0,
           loyalty_tier  = 'starter',
           last_reset    = CURRENT_DATE,
           updated_at    = NOW()
     WHERE monthly_spend > 0;

    -- 2. Log dans settings pour suivi admin
    INSERT INTO public.settings (key, value, updated_at)
    VALUES ('last_monthly_reset', to_jsonb(CURRENT_TIMESTAMP::TEXT), NOW())
    ON CONFLICT (key) DO UPDATE
       SET value      = to_jsonb(CURRENT_TIMESTAMP::TEXT),
           updated_at = NOW();
  $$
);

-- ═══════════════════════════════════════
-- FONCTION CHECKOUT
-- Crée la commande, copie le panier, VIDE le panier
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION checkout(
  p_user_id      UUID,
  p_governorate  TEXT,
  p_city         TEXT,
  p_area         TEXT DEFAULT '',
  p_street       TEXT DEFAULT '',
  p_house        TEXT DEFAULT '',
  p_phone        TEXT DEFAULT '',
  p_coupon_code  TEXT DEFAULT NULL,
  p_notes        TEXT DEFAULT NULL
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order_id    UUID;
  v_subtotal    NUMERIC := 0;
  v_deliv_fee   NUMERIC := 0;
  v_loy_disc    NUMERIC := 0;
  v_coup_disc   NUMERIC := 0;
  v_total       NUMERIC;
  v_loy_pct     NUMERIC := 0;
  v_coup_id     UUID;
  v_coup_pct    NUMERIC := 0;
  v_zone_id     UUID;
  v_has_gift    BOOLEAN := FALSE;
  v_tier        loyalty_tier;
BEGIN
  -- Palier de l'utilisateur
  SELECT loyalty_tier INTO v_tier FROM public.profiles WHERE id = p_user_id;

  -- Sous-total panier
  SELECT COALESCE(SUM(ci.quantity * COALESCE(p.promo_price, p.price)), 0)
    INTO v_subtotal
    FROM public.cart_items ci
    JOIN public.products   p  ON p.id = ci.product_id
   WHERE ci.user_id = p_user_id;

  IF v_subtotal = 0 THEN RAISE EXCEPTION 'Panier vide'; END IF;

  -- Frais de livraison
  SELECT id, price INTO v_zone_id, v_deliv_fee
    FROM public.delivery_zones
   WHERE governorate = p_governorate
     AND city        = p_city
     AND (area = p_area OR area = '' OR area IS NULL)
     AND is_active   = TRUE
   ORDER BY CASE WHEN area = p_area THEN 0 ELSE 1 END
   LIMIT 1;

  -- Remise fidélité
  CASE v_tier
    WHEN 'vip'    THEN v_loy_pct := 15;
    WHEN 'gold'   THEN v_loy_pct := 10;
    WHEN 'silver' THEN v_loy_pct := 7;
    WHEN 'bronze' THEN v_loy_pct := 5;
    ELSE               v_loy_pct := 3;
  END CASE;
  v_loy_disc := ROUND(v_subtotal * v_loy_pct / 100, 3);

  -- Remise coupon
  IF p_coupon_code IS NOT NULL THEN
    SELECT id, discount_pct INTO v_coup_id, v_coup_pct
      FROM public.coupons
     WHERE code       = UPPER(p_coupon_code)
       AND is_active  = TRUE
       AND (valid_until IS NULL OR valid_until > NOW())
       AND (max_uses   IS NULL OR current_uses < max_uses)
       AND min_order  <= v_subtotal;

    IF v_coup_id IS NOT NULL THEN
      v_coup_disc := ROUND(v_subtotal * v_coup_pct / 100, 3);
      UPDATE public.coupons SET current_uses = current_uses + 1 WHERE id = v_coup_id;
    END IF;
  END IF;

  -- Cadeau ≥200 DT
  IF v_subtotal >= 200 THEN v_has_gift := TRUE; END IF;

  -- Total final
  v_total := GREATEST(0, v_subtotal - v_loy_disc - v_coup_disc + v_deliv_fee);

  -- Insertion commande
  INSERT INTO public.orders (
    user_id, subtotal, loyalty_discount, coupon_discount, delivery_fee, total,
    coupon_id, coupon_code, delivery_zone_id,
    governorate, city, area, street, house_number, customer_phone,
    has_gift, notes
  ) VALUES (
    p_user_id, v_subtotal, v_loy_disc, v_coup_disc, v_deliv_fee, v_total,
    v_coup_id, p_coupon_code, v_zone_id,
    p_governorate, p_city, p_area, p_street, p_house, p_phone,
    v_has_gift, p_notes
  ) RETURNING id INTO v_order_id;

  -- Copie du panier vers order_items
  INSERT INTO public.order_items (order_id, product_id, name_ar, name_fr, unit_price, quantity, subtotal)
  SELECT v_order_id,
         ci.product_id,
         p.name_ar,
         p.name_fr,
         COALESCE(p.promo_price, p.price),
         ci.quantity,
         ci.quantity * COALESCE(p.promo_price, p.price)
    FROM public.cart_items ci
    JOIN public.products   p ON p.id = ci.product_id
   WHERE ci.user_id = p_user_id;

  -- Log statut initial
  INSERT INTO public.order_status_history(order_id, status)
  VALUES (v_order_id, 'received');

  -- ★ VIDER LE PANIER après checkout ← CORRECTION #2
  DELETE FROM public.cart_items WHERE user_id = p_user_id;

  RETURN v_order_id;
END;$$;

-- ═══════════════════════════════════════
-- FONCTION : upsert item panier (set/merge quantité)
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION upsert_cart_item(
  p_user_id    UUID,
  p_product_id UUID,
  p_quantity   INT
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_quantity <= 0 THEN
    DELETE FROM public.cart_items
     WHERE user_id = p_user_id AND product_id = p_product_id;
  ELSE
    INSERT INTO public.cart_items(user_id, product_id, quantity)
    VALUES (p_user_id, p_product_id, p_quantity)
    ON CONFLICT (user_id, product_id)
    DO UPDATE SET quantity = p_quantity, updated_at = NOW();
  END IF;
END;$$;

-- ═══════════════════════════════════════
-- FONCTION : valider un coupon
-- ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION validate_coupon(p_code TEXT, p_subtotal NUMERIC)
RETURNS TABLE(valid BOOLEAN, discount_pct NUMERIC, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v RECORD;
BEGIN
  SELECT * INTO v FROM public.coupons
   WHERE code = UPPER(p_code) AND is_active = TRUE
     AND (valid_until IS NULL OR valid_until > NOW())
     AND (max_uses    IS NULL OR current_uses < max_uses);

  IF v.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 0::NUMERIC, 'Code invalide ou expiré';
  ELSIF v.min_order > p_subtotal THEN
    RETURN QUERY SELECT FALSE, 0::NUMERIC,
      'Minimum ' || v.min_order || ' DT requis';
  ELSE
    RETURN QUERY SELECT TRUE, v.discount_pct, 'Coupon appliqué !';
  END IF;
END;$$;

-- ═══════════════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════════════

-- Profils
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profiles_own" ON public.profiles FOR ALL USING (auth.uid() = id);

-- Panier ← utilisateur uniquement
ALTER TABLE public.cart_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cart_own"    ON public.cart_items FOR ALL USING (auth.uid() = user_id);

-- Commandes
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "orders_own"  ON public.orders FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "orders_ins"  ON public.orders FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Items commande
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "oitems_own" ON public.order_items FOR SELECT
  USING (order_id IN (SELECT id FROM public.orders WHERE user_id = auth.uid()));

-- Historique statuts
ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ostatus_own" ON public.order_status_history FOR SELECT
  USING (order_id IN (SELECT id FROM public.orders WHERE user_id = auth.uid()));

-- Lecture publique : produits, catégories, zones
ALTER TABLE public.products       ENABLE ROW LEVEL SECURITY;
CREATE POLICY "products_pub"  ON public.products       FOR SELECT USING (is_active = TRUE);
ALTER TABLE public.categories     ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cats_pub"      ON public.categories     FOR SELECT USING (is_active = TRUE);
ALTER TABLE public.delivery_zones ENABLE ROW LEVEL SECURITY;
CREATE POLICY "zones_pub"     ON public.delivery_zones FOR SELECT USING (is_active = TRUE);

-- Coupons (actifs uniquement)
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "coupons_pub" ON public.coupons FOR SELECT
  USING (is_active = TRUE AND (valid_until IS NULL OR valid_until > NOW()));

-- Promotions
ALTER TABLE public.promotions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "promos_pub" ON public.promotions FOR SELECT USING (is_active = TRUE);

-- Favoris
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
CREATE POLICY "favs_own" ON public.favorites FOR ALL USING (auth.uid() = user_id);

-- Notifications
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "notifs_own" ON public.notifications FOR ALL
  USING (user_id IS NULL OR auth.uid() = user_id);

-- Chats IA
ALTER TABLE public.ai_chats ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ai_own" ON public.ai_chats FOR ALL USING (auth.uid() = user_id);

-- Paramètres (lecture publique)
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "settings_pub" ON public.settings FOR SELECT USING (TRUE);

-- ═══════════════════════════════════════
-- GRANTS
-- ═══════════════════════════════════════
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.products, public.categories, public.delivery_zones,
               public.coupons, public.promotions, public.settings TO anon, authenticated;
GRANT ALL ON
  public.profiles, public.cart_items, public.orders, public.order_items,
  public.order_status_history, public.favorites, public.notifications,
  public.ai_chats
  TO authenticated;
GRANT EXECUTE ON FUNCTION checkout        TO authenticated;
GRANT EXECUTE ON FUNCTION validate_coupon TO authenticated;
GRANT EXECUTE ON FUNCTION upsert_cart_item TO authenticated;

-- ═══════════════════════════════════════
-- FIN DU SCHÉMA
-- Prochaines étapes :
--   1. Activer pg_cron dans Supabase Dashboard → Extensions
--   2. Déployer ce SQL dans l'éditeur SQL de Supabase
--   3. Vérifier le job cron : SELECT * FROM cron.job;
--   4. Tester : SELECT * FROM cart_items WHERE user_id = '<UUID>';
-- ═══════════════════════════════════════
