Rails.application.routes.draw do
  # Bare domain (e.g. admin.frenchworksheethub.com) shows the admin login page.
  # Once signed in, the login action redirects on to the dashboard.
  root to: "admin/sessions#new"

  resources :orders, only: [:create, :show]
  post "/webhooks/razorpay", to: "webhooks#razorpay"
  get "/download/:id", to: "downloads#show", as: :download_order

  namespace :admin do
    get    "/login",  to: "sessions#new",     as: :login
    post   "/login",  to: "sessions#create"
    delete "/logout", to: "sessions#destroy", as: :logout

    get "/", to: "dashboard#index", as: :root

    get  "/orders",              to: "orders#index",        as: :orders
    get  "/orders/:id",          to: "orders#show",         as: :order
    post "/orders/:id/resend",   to: "orders#resend_email", as: :resend_email_order
    post "/orders/:id/fulfill",  to: "orders#fulfill",      as: :fulfill_order

    get    "/products",          to: "products#index",   as: :products
    get    "/products/new",      to: "products#new",     as: :new_product
    get    "/products/:id/edit", to: "products#edit",    as: :edit_product
    get    "/products/:id",      to: "products#show",    as: :product
    post   "/products",          to: "products#create"
    patch  "/products/:id",      to: "products#update"
    put    "/products/:id",      to: "products#update"
    delete "/products/:id",      to: "products#destroy"
  end

  get "/products", to: "products#index"
end
