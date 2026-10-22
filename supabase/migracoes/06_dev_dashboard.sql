-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- =====================================================================
-- Demanda de campanha a partir de um listing concluído
-- =====================================================================
alter table public.listings add column if not exists demanda_ads_id uuid references public.ads_registros(id) on delete set null;

-- =====================================================================
-- Modo dev
-- A palavra-chave fica numa tabela que o app não consegue ler;
-- só as funções abaixo comparam o que foi digitado.
-- =====================================================================
create table public.segredos (
  chave text primary key,
  valor text not null
);
alter table public.segredos enable row level security;
revoke all on public.segredos from anon, authenticated;

create or replace function public.verificar_modo_dev(p_chave text)
returns boolean language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  if auth.uid() is null then return false; end if;
  select exists (select 1 from public.segredos where chave = 'modo_dev' and valor = p_chave) into ok;
  if not ok then perform pg_sleep(1); end if;   -- atrasa tentativas de adivinhar
  return ok;
end; $$;

create or replace function public.dev_definir_colaborador(p_chave text, p_id uuid, p_funcao public.funcao_colaborador, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.verificar_modo_dev(p_chave) then raise exception 'Palavra-chave do modo dev incorreta'; end if;
  if p_ativo and p_funcao is null then raise exception 'Defina a função antes de liberar o acesso'; end if;
  update public.colaboradores set funcao = p_funcao, ativo = p_ativo where id = p_id;
end; $$;

revoke execute on function public.verificar_modo_dev(text) from public, anon;
revoke execute on function public.dev_definir_colaborador(text, uuid, public.funcao_colaborador, boolean) from public, anon;
grant  execute on function public.verificar_modo_dev(text) to authenticated;
grant  execute on function public.dev_definir_colaborador(text, uuid, public.funcao_colaborador, boolean) to authenticated;

-- A palavra-chave do modo dev fica em supabase/modo-dev.sql (fora do GitHub).

