-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Configurações gerais e Listings
-- Rota de cada solicitação: solicitado → em processo → catalogação → concluído
-- =====================================================================
create table public.configuracoes (
  chave          text primary key,
  valor          text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now()
);
insert into public.configuracoes (chave) values ('planilha_catalogacao_padrao');

create or replace function public.config_autor()
returns trigger language plpgsql as $$
begin new.atualizado_por = auth.uid(); new.atualizado_em = now(); return new; end; $$;

create trigger configuracoes_autor
  before update on public.configuracoes
  for each row execute function public.config_autor();

create type public.etapa_listing       as enum ('solicitado', 'em_processo', 'catalogacao', 'concluido');
create type public.tipo_evento_listing as enum ('etapa', 'alteracao');

create table public.listings (
  id                   uuid primary key default gen_random_uuid(),
  numero               bigint generated always as identity unique,   -- número da solicitação
  cliente_id           uuid not null references public.clientes(id) on delete cascade,
  qtd_produtos         integer not null check (qtd_produtos > 0),
  data_pedido          date not null default current_date,
  planilha_url         text,
  listing_url          text,
  etapa                public.etapa_listing not null default 'solicitado',
  data_criacao_listing date,
  catalogados          integer not null default 0,
  impedimento          text,
  criado_por           uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),
  concluido_em         timestamptz,
  constraint catalogados_validos check (catalogados >= 0 and catalogados <= qtd_produtos),
  constraint aprovado_tem_data   check (etapa in ('solicitado', 'em_processo') or data_criacao_listing is not null),
  constraint concluido_completo  check (etapa <> 'concluido' or catalogados = qtd_produtos)
);
create index on public.listings (cliente_id);
create index on public.listings (etapa);

create table public.listing_eventos (
  id         bigint generated always as identity primary key,
  listing_id uuid not null references public.listings(id) on delete cascade,
  tipo       public.tipo_evento_listing not null,
  etapa_de   public.etapa_listing,
  etapa_para public.etapa_listing,
  nota       text,
  autor      uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em  timestamptz not null default now()
);
create index on public.listing_eventos (listing_id, criado_em);

-- Antes de gravar: datas e link padrão da planilha
create or replace function public.listing_antes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_em = now();
  if tg_op = 'INSERT' and nullif(trim(coalesce(new.planilha_url, '')), '') is null then
    select valor into new.planilha_url from public.configuracoes where chave = 'planilha_catalogacao_padrao';
  end if;
  if new.etapa = 'concluido' then
    if tg_op = 'INSERT' or old.etapa <> 'concluido' then new.concluido_em = now(); end if;
  else
    new.concluido_em = null;
  end if;
  return new;
end; $$;

create trigger listings_antes
  before insert or update on public.listings
  for each row execute function public.listing_antes();

-- Depois de gravar: toda mudança de etapa vai para o histórico
create or replace function public.listing_depois()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.listing_eventos (listing_id, tipo, etapa_para, autor) values (new.id, 'etapa', new.etapa, auth.uid());
  elsif new.etapa is distinct from old.etapa then
    insert into public.listing_eventos (listing_id, tipo, etapa_de, etapa_para, autor) values (new.id, 'etapa', old.etapa, new.etapa, auth.uid());
  end if;
  return null;
end; $$;

create trigger listings_depois
  after insert or update on public.listings
  for each row execute function public.listing_depois();

alter table public.configuracoes   enable row level security;
alter table public.listings        enable row level security;
alter table public.listing_eventos enable row level security;

create policy "ver configuracoes"    on public.configuracoes for select to authenticated using (public.eh_ativo());
create policy "editar configuracoes" on public.configuracoes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
revoke insert, delete on public.configuracoes from anon, authenticated;

create policy "ver listings"     on public.listings for select to authenticated using (public.eh_ativo());
create policy "criar listings"   on public.listings for insert to authenticated with check (public.eh_ativo());
create policy "editar listings"  on public.listings for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir listings" on public.listings for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

-- Pelo app só entram pedidos de alteração; mudanças de etapa são registradas sozinhas
create policy "ver eventos listing"       on public.listing_eventos for select to authenticated using (public.eh_ativo());
create policy "registrar alteracao"       on public.listing_eventos for insert to authenticated with check (public.eh_ativo() and tipo = 'alteracao');
revoke update, delete on public.listing_eventos from anon, authenticated;

