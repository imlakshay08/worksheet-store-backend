Rails.application.routes.draw do
  resources :orders, only: [:create, :show]
  post "/webhooks/razorpay", to: "webhooks#razorpay"
  get "/download/:id", to: "downloads#show", as: :download_order

  namespace :admin do
    get "/products", to: "products#index", as: :products
    get "/products/new", to: "products#new", as: :new_product
    get "/products/:id/edit", to: "products#edit", as: :edit_product
    get "/products/:id", to: "products#show", as: :product
    post "/products", to: "products#create"
    patch "/products/:id", to: "products#update"
    put "/products/:id", to: "products#update"
    delete "/products/:id", to: "products#destroy"
  end

  get "/products", to: "products#index"
end