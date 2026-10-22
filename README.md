# Carteira de clientes Amazon

Sistema interno da equipe para acompanhar cada cliente na Amazon: status da conta, tendência de faturamento, Ads, listings, promoções, eventos, problemas e chamados.

Feito em um único `index.html`, com banco e login no [Supabase](https://supabase.com) e hospedado no GitHub Pages.

## Estrutura

```
index.html                 o app inteiro
supabase/schema.sql        cria o banco do zero (projeto novo)
supabase/migracoes/        só para quem já tinha um banco de versões anteriores
supabase/modo-dev.sql      palavra-chave do modo dev (fica fora do GitHub)
```

## Colocar no ar

### 1. Banco no Supabase
1. Crie um projeto no Supabase.
2. Abra o **SQL Editor**, cole todo o conteúdo de `supabase/schema.sql` e clique em **Run**.
3. Ainda no SQL Editor, rode `supabase/modo-dev.sql` (é ele que define a palavra-chave do modo dev).
4. Em **Project Settings → API**, copie a **Project URL** e a chave **anon public**.

> Se você já tinha um banco de uma versão anterior, **não** rode o `schema.sql`. Rode só as migrações de `supabase/migracoes/` que ainda não rodou, na ordem dos números.

### 2. Configurar o app
No começo do `<script>` do `index.html`, troque:

```js
const SUPABASE_URL = 'COLE_A_URL_DO_PROJETO';
const SUPABASE_ANON_KEY = 'COLE_A_ANON_KEY';
```

pela URL e pela chave copiadas. A chave anon pode ficar pública: quem protege os dados são as regras de acesso do banco.

### 3. Publicar no GitHub Pages
1. Crie um repositório no GitHub e suba os arquivos desta pasta.
2. No repositório, vá em **Settings → Pages**.
3. Em **Source**, escolha **Deploy from a branch**, a branch **main** e a pasta **/ (root)**. Salve.
4. Em um ou dois minutos o endereço aparece no topo da mesma página, no formato `https://SEU-USUARIO.github.io/NOME-DO-REPOSITORIO/`.

### 4. Ligar o login ao endereço
No Supabase, em **Authentication → URL Configuration**, coloque o endereço do GitHub Pages em **Site URL** e também em **Redirect URLs**. Assim o link de confirmação de e-mail volta para o app.

### 5. Primeiro acesso
1. Abra o app, clique em **Criar conta de colaborador** e confirme o e-mail.
2. Para virar HEAD, entre em **Configurações → Modo dev**, digite a palavra-chave e, na aba **Equipe**, defina sua função como HEAD.
   Outra opção é rodar no SQL Editor: `update public.colaboradores set funcao = 'head' where email = 'seu@email.com';`

## Atualizar depois
Edite o `index.html` (no próprio GitHub, pelo ícone de lápis, ou subindo o arquivo de novo). O GitHub Pages publica sozinho em cerca de um minuto. Se a mudança vier com SQL novo, rode a migração no Supabase **antes** de subir o HTML.

## Segurança
- Nunca suba o `supabase/modo-dev.sql`. Ele já está no `.gitignore`.
- Como qualquer pessoa com o link consegue criar conta, troque a palavra-chave do modo dev por uma mais longa assim que configurar seu acesso.
- Para fechar o cadastro, desligue **Allow new users to sign up** no Supabase (em Authentication) e convide a equipe pelo painel.
