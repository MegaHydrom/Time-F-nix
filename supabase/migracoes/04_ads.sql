-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Aba Ads
-- Situação atual (um texto por cliente) e timeline de registros por data:
-- alterações realizadas e demandas. Tudo isso aparece só na aba Ads.
-- =====================================================================
create type public.tipo_registro_ads as enum ('alteracao', 'demanda');

create table public.ads_situacao (
  cliente_id     uuid primary key references public.clientes(id) on delete cascade,
  texto          text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now()
);

create table public.ads_registros (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  tipo          public.tipo_registro_ads not null,
  data          date not null default current_date,
  texto         text not null,
  concluida     boolean not null default false,   -- só vale para demandas
  concluida_em  timestamptz,
  autor         uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index on public.ads_registros (cliente_id, data desc);

create or replace function public.ads_situacao_autor()
returns trigger language plpgsql as $$
begin
  new.atualizado_por = auth.uid();
  new.atualizado_em = now();
  return new;
end; $$;

create trigger ads_situacao_autor
  before insert or update on public.ads_situacao
  for each row execute function public.ads_situacao_autor();

create or replace function public.ads_registro_datas()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.tipo <> 'demanda' then new.concluida = false; end if;
  if new.concluida then
    if tg_op = 'INSERT' or not old.concluida then new.concluida_em = now(); end if;
  else
    new.concluida_em = null;
  end if;
  return new;
end; $$;

create trigger ads_registros_datas
  before insert or update on public.ads_registros
  for each row execute function public.ads_registro_datas();

alter table public.ads_situacao  enable row level security;
alter table public.ads_registros enable row level security;

create policy "ver situacao ads"    on public.ads_situacao for select to authenticated using (public.eh_ativo());
create policy "criar situacao ads"  on public.ads_situacao for insert to authenticated with check (public.eh_ativo());
create policy "editar situacao ads" on public.ads_situacao for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());

create policy "ver registros ads"     on public.ads_registros for select to authenticated using (public.eh_ativo());
create policy "criar registros ads"   on public.ads_registros for insert to authenticated with check (public.eh_ativo());
create policy "editar registros ads"  on public.ads_registros for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir registros ads" on public.ads_registros for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and autor = auth.uid()));

