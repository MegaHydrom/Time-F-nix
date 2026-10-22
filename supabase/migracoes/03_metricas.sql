-- Rode isto se você já tinha rodado o schema.sql antes desta versão.
-- Num projeto novo, basta o schema.sql atualizado.

-- Guarda o nome que a conta tem na planilha, para as próximas importações reconhecerem sozinhas
alter table public.clientes add column nome_planilha text;
grant update (nome_planilha) on public.clientes to authenticated;
