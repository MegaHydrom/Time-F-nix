-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Problemas e chamados
-- Uma conta pode ter vários problemas; cada problema pode gerar vários chamados.
-- Concluir um chamado NÃO resolve o problema: cada um tem o próprio status.
-- =====================================================================
create type public.gravidade_problema as enum ('baixa', 'media', 'alta', 'critica');
create type public.status_problema    as enum ('aberto', 'em_andamento', 'resolvido');
create type public.status_chamado     as enum ('a_abrir', 'aberto', 'concluido');

create table public.problemas (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  titulo        text not null,
  descricao     text,
  gravidade     public.gravidade_problema not null default 'media',
  status        public.status_problema not null default 'aberto',
  responsavel   uuid references public.colaboradores(id) on delete set null,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  resolvido_em  timestamptz
);
create index on public.problemas (cliente_id);

create table public.chamados (
  id            uuid primary key default gen_random_uuid(),
  problema_id   uuid not null references public.problemas(id) on delete cascade,
  assunto       text not null,
  observacoes   text,
  status        public.status_chamado not null default 'a_abrir',
  responsavel   uuid references public.colaboradores(id) on delete set null,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  aberto_em     timestamptz,
  concluido_em  timestamptz
);
create index on public.chamados (problema_id);
create index on public.chamados (status);

-- Datas preenchidas automaticamente
create or replace function public.datas_problema()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.status = 'resolvido' then
    if tg_op = 'INSERT' or old.status <> 'resolvido' then new.resolvido_em = now(); end if;
  else
    new.resolvido_em = null;
  end if;
  return new;
end; $$;

create trigger problemas_datas
  before insert or update on public.problemas
  for each row execute function public.datas_problema();

create or replace function public.datas_chamado()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.status in ('aberto', 'concluido') and new.aberto_em is null then new.aberto_em = now(); end if;
  if new.status = 'concluido' then
    if tg_op = 'INSERT' or old.status <> 'concluido' then new.concluido_em = now(); end if;
  else
    new.concluido_em = null;
  end if;
  return new;
end; $$;

create trigger chamados_datas
  before insert or update on public.chamados
  for each row execute function public.datas_chamado();

-- Regras de acesso: todo colaborador ativo vê, cria e edita;
-- excluir fica com quem criou ou com o HEAD.
alter table public.problemas enable row level security;
alter table public.chamados  enable row level security;

create policy "ver problemas"     on public.problemas for select to authenticated using (public.eh_ativo());
create policy "criar problemas"   on public.problemas for insert to authenticated with check (public.eh_ativo());
create policy "editar problemas"  on public.problemas for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir problemas" on public.problemas for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver chamados"     on public.chamados for select to authenticated using (public.eh_ativo());
create policy "criar chamados"   on public.chamados for insert to authenticated with check (public.eh_ativo());
create policy "editar chamados"  on public.chamados for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir chamados" on public.chamados for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

