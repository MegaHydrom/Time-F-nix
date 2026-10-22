-- ARQUIVO PRIVADO: está no .gitignore e não deve ir para o GitHub.
-- Rode no SQL Editor do Supabase depois do schema.sql para definir a palavra-chave do modo dev.
-- Para trocar a palavra depois, rode só o update.

insert into public.segredos (chave, valor) values ('modo_dev', 'Amora')
on conflict (chave) do update set valor = excluded.valor;

-- Trocar a palavra-chave:
-- update public.segredos set valor = 'uma-palavra-bem-mais-longa' where chave = 'modo_dev';
