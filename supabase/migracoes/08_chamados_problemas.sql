-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Chamados independentes: nascem com cliente e data,
-- e podem ser ligados a um problema depois
-- =====================================================================
alter table public.chamados add column if not exists cliente_id uuid references public.clientes(id) on delete cascade;
update public.chamados ch set cliente_id = p.cliente_id from public.problemas p where p.id = ch.problema_id and ch.cliente_id is null;
alter table public.chamados alter column cliente_id set not null;
alter table public.chamados alter column problema_id drop not null;
alter table public.chamados alter column assunto drop not null;
alter table public.chamados add column if not exists data_chamado date not null default current_date;
update public.chamados set data_chamado = criado_em::date where data_chamado = current_date and criado_em::date <> current_date;

-- Excluir um problema não apaga mais os chamados: eles só ficam sem problema vinculado
alter table public.chamados drop constraint if exists chamados_problema_id_fkey;
alter table public.chamados add constraint chamados_problema_id_fkey
  foreign key (problema_id) references public.problemas(id) on delete set null;
create index if not exists chamados_cliente_idx on public.chamados (cliente_id);

-- O problema vinculado precisa ser do mesmo cliente do chamado
create or replace function public.chamado_mesmo_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.problema_id is not null and not exists (
    select 1 from public.problemas where id = new.problema_id and cliente_id = new.cliente_id
  ) then
    raise exception 'O problema escolhido é de outro cliente';
  end if;
  return new;
end; $$;

drop trigger if exists chamados_mesmo_cliente on public.chamados;
create trigger chamados_mesmo_cliente
  before insert or update on public.chamados
  for each row execute function public.chamado_mesmo_cliente();

