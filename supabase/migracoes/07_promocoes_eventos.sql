-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Promoções e eventos
-- =====================================================================
create type public.tipo_promocao as enum ('desconto_preco', 'melhor_oferta', 'cupom', 'promocao', 'desconto_pix');

create table public.promocoes (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  tipo          public.tipo_promocao not null,
  percentual    numeric(5,2) not null check (percentual > 0 and percentual <= 100),
  data_inicio   date not null,
  data_fim      date not null,              -- último dia da promoção
  observacao    text,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint periodo_valido check (data_fim >= data_inicio)
);
create index on public.promocoes (cliente_id);
create index on public.promocoes (data_fim);

create table public.eventos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  data_inicio date,                         -- opcional: o evento pode ser anunciado sem data
  data_fim    date,
  criado_por  uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em   timestamptz not null default now(),
  constraint periodo_evento check (data_inicio is null or data_fim is null or data_fim >= data_inicio)
);

-- Etapas: 1 informar o cliente, 2 cliente interessado, 3 definir produtos, 4 tudo pronto
create table public.evento_clientes (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references public.eventos(id) on delete cascade,
  cliente_id     uuid not null references public.clientes(id) on delete cascade,
  etapa          smallint not null default 1 check (etapa between 1 and 4),
  nao_participa  boolean not null default false,
  planilha_url   text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now(),
  unique (evento_id, cliente_id)
);
create index on public.evento_clientes (evento_id);

create or replace function public.tocar_evento_cliente()
returns trigger language plpgsql as $$
begin new.atualizado_por = auth.uid(); new.atualizado_em = now(); return new; end; $$;

create trigger evento_clientes_autor
  before insert or update on public.evento_clientes
  for each row execute function public.tocar_evento_cliente();

-- Evento novo: entram todos os clientes ativos e pausados
create or replace function public.preencher_evento()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.evento_clientes (evento_id, cliente_id)
  select new.id, c.id from public.clientes c where c.status in ('ativo', 'pausado')
  on conflict do nothing;
  return new;
end; $$;

create trigger eventos_preencher
  after insert on public.eventos
  for each row execute function public.preencher_evento();

-- Cliente novo: entra nos eventos cuja data de início (data de corte) ainda não chegou,
-- ou que ainda não têm data
create or replace function public.cliente_em_eventos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('ativo', 'pausado') then
    insert into public.evento_clientes (evento_id, cliente_id)
    select e.id, new.id from public.eventos e
    where e.data_inicio is null or current_date < e.data_inicio
    on conflict do nothing;
  end if;
  return new;
end; $$;

create trigger clientes_em_eventos
  after insert on public.clientes
  for each row execute function public.cliente_em_eventos();

create or replace function public.tocar_promocao()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end; $$;

create trigger promocoes_atualizado
  before update on public.promocoes
  for each row execute function public.tocar_promocao();

alter table public.promocoes       enable row level security;
alter table public.eventos         enable row level security;
alter table public.evento_clientes enable row level security;

create policy "ver promocoes"     on public.promocoes for select to authenticated using (public.eh_ativo());
create policy "criar promocoes"   on public.promocoes for insert to authenticated with check (public.eh_ativo());
create policy "editar promocoes"  on public.promocoes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir promocoes" on public.promocoes for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver eventos"     on public.eventos for select to authenticated using (public.eh_ativo());
create policy "criar eventos"   on public.eventos for insert to authenticated with check (public.eh_ativo());
create policy "editar eventos"  on public.eventos for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir eventos" on public.eventos for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver clientes do evento"     on public.evento_clientes for select to authenticated using (public.eh_ativo());
create policy "incluir cliente no evento"  on public.evento_clientes for insert to authenticated with check (public.eh_ativo());
create policy "atualizar cliente no evento" on public.evento_clientes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "tirar cliente do evento"    on public.evento_clientes for delete to authenticated using (public.eh_ativo());

