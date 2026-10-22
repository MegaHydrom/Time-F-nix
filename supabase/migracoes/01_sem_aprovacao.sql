-- Só rode isto se você JÁ tinha rodado a versão anterior do schema.sql.
-- Num projeto novo, rode apenas o schema.sql atualizado.

alter table public.colaboradores rename column aprovado to ativo;
alter table public.colaboradores alter column ativo set default true;
update public.colaboradores set ativo = true;

-- As regras de acesso continuam apontando para a função renomeada
alter function public.eh_aprovado() rename to eh_ativo;

create or replace function public.eh_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.colaboradores where id = auth.uid() and ativo and funcao is not null);
$$;

create or replace function public.eh_head()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.colaboradores where id = auth.uid() and ativo and funcao = 'head');
$$;

create or replace function public.novo_colaborador()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.colaboradores (id, nome, email, funcao)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'nome'), ''), split_part(new.email, '@', 1)),
    new.email,
    case when new.raw_user_meta_data->>'funcao' in ('gestor_ads', 'operador_contas', 'gestor_contas')
         then (new.raw_user_meta_data->>'funcao')::public.funcao_colaborador end
  );
  return new;
end; $$;

create or replace function public.alterar_status(p_cliente uuid, p_status public.status_cliente, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_atual public.status_cliente;
begin
  if not public.eh_ativo() then raise exception 'Sem permissão para alterar status'; end if;
  select status into v_atual from public.clientes where id = p_cliente for update;
  if not found then raise exception 'Cliente não encontrado'; end if;
  if v_atual = p_status then return; end if;
  update public.clientes set status = p_status where id = p_cliente;
  insert into public.historico_status (cliente_id, status_anterior, status_novo, motivo, alterado_por)
  values (p_cliente, v_atual, p_status, nullif(trim(p_motivo), ''), auth.uid());
end; $$;

drop function public.definir_colaborador(uuid, public.funcao_colaborador, boolean);
create function public.definir_colaborador(p_id uuid, p_funcao public.funcao_colaborador, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_head() then raise exception 'Apenas o HEAD pode gerenciar a equipe'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode alterar o próprio acesso'; end if;
  if p_ativo and p_funcao is null then raise exception 'Defina a função antes de liberar o acesso'; end if;
  update public.colaboradores set funcao = p_funcao, ativo = p_ativo where id = p_id;
end; $$;
revoke execute on function public.definir_colaborador(uuid, public.funcao_colaborador, boolean) from public, anon;
grant  execute on function public.definir_colaborador(uuid, public.funcao_colaborador, boolean) to authenticated;
