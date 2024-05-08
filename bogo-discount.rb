# ================================ Customizable Settings ================================
# ================================================================
# Buy V of Product W, Get X of Product Y for Z Discount
#
# Buy a certain number of matching items, get a certain number of
# a different set of matching items with the entered discount
# applied. For example:
#
#   "Buy 2 t-shirts, get 1 hat for 10% off"
#
#   - 'buy_product_selector_match_type' determines whether we look
#     for products that do or don't match the entered selectors.
#     Can be:
#       - ':include' to check if the product does match
#       - ':exclude' to make sure the product doesn't match
#   - 'buy_product_selector_type' determines how eligible products
#     will be identified. Can be:
#       - ':tag' to find products by tag
#       - ':type' to find products by type
#       - ':vendor' to find products by vendor
#       - ':product_id' to find products by ID
#       - ':variant_id' to find products by variant ID
#       - ':subscription' to find subscription products
#       - ':all' for all products
#   - 'buy_product_selectors' is a list of identifiers (from above)
#     for qualifying products. Product/Variant ID lists should only
#     contain numbers (ie. no quotes). If ':all' is used, this
#     can also be 'nil'.
#   - 'quantity_to_buy' is the number of products needed to
#     qualify
#   - 'get_selector_match_type' is the same idea as the "Buy"
#     version above
#   - 'get_product_selector_type' is the same idea as the "Buy"
#     version above
#   - 'get_product_selectors' is the same idea as the "Buy"
#     version above
#   - 'quantity_to_discount' is the number of products to discount
#   - 'allow_incomplete_bundle' determines whether a portion of
#     the items to discount can be discounted, or all items
#     need to be present. Can be:
#       - 'true'
#       - 'false'
#   - 'discount_type' is the type of discount to provide. Can be
#     either:
#       - ':percent'
#       - ':dollar'
#   - 'discount_amount' is the percentage/dollar discount to
#     apply (per item)
#   - 'discount_message' is the message to show when a discount
#     is applied
# ================================================================
BUYVOFW_GETXOFY_FORZ = [
  
  {
    buy_product_selector_match_type: :include,
    buy_product_selector_type: :product_id,
    buy_product_selectors: [7711893487793],
    quantity_to_buy: 1,
    get_product_selector_match_type: :include,
    get_product_selector_type: :product_id,
    get_product_selectors: [7712977518769],
    quantity_to_discount: 5,
    allow_incomplete_bundle: true,
    discount_type: :dollar,
    discount_amount: 30,
    discount_message: '$30 Off Lens with Purchase of Havok!',
  },
]

# ================================ Script Code (do not edit) ================================
# ================================================================
# ProductSelector
#
# Finds matching products by the entered criteria.
# ================================================================
class ProductSelector
  def initialize(match_type, selector_type, selectors)
    @match_type = match_type
    @comparator = match_type == :include ? 'any?' : 'none?'
    @selector_type = selector_type
    @selectors = selectors
  end

  def match?(line_item)
    if self.respond_to?(@selector_type)
      self.send(@selector_type, line_item)
    else
      raise RuntimeError.new('Invalid product selector type')
    end
  end

  def tag(line_item)
    product_tags = line_item.variant.product.tags.map { |tag| tag.downcase.strip }
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@selectors & product_tags).send(@comparator)
  end

  def type(line_item)
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@match_type == :include) == @selectors.include?(line_item.variant.product.product_type.downcase.strip)
  end

  def vendor(line_item)
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@match_type == :include) == @selectors.include?(line_item.variant.product.vendor.downcase.strip)
  end

  def product_id(line_item)
    (@match_type == :include) == @selectors.include?(line_item.variant.product.id)
  end

  def variant_id(line_item)
    (@match_type == :include) == @selectors.include?(line_item.variant.id)
  end

  def subscription(line_item)
    !line_item.selling_plan_id.nil?
  end

  def all(line_item)
    true
  end
end

# ================================================================
# DiscountApplicator
#
# Applies the entered discount to the supplied line item.
# ================================================================
class DiscountApplicator
  def initialize(discount_type, discount_amount, discount_message)
    @discount_type = discount_type
    @discount_message = discount_message

    @discount_amount = if discount_type == :percent
      1 - (discount_amount * 0.01)
    else
      Money.new(cents: 100) * discount_amount
    end
  end

  def apply(line_item)
    new_line_price = if @discount_type == :percent
      line_item.line_price * @discount_amount
    else
      [line_item.line_price - (@discount_amount * line_item.quantity), Money.zero].max
    end

    line_item.change_line_price(new_line_price, message: @discount_message)
  end
end

# ================================================================
# DiscountLoop
#
# Loops through the supplied line items and discounts the supplied
# number of items by the supplied discount.
# ================================================================
class DiscountLoop
  def initialize(discount_applicator)
    @discount_applicator = discount_applicator
  end

  def loop_items(cart, line_items, num_to_discount)
    line_items.each do |line_item|
      break if num_to_discount <= 0

      if line_item.quantity > num_to_discount
        split_line_item = line_item.split(take: num_to_discount)
        @discount_applicator.apply(split_line_item)
        position = cart.line_items.find_index(line_item)
        cart.line_items.insert(position + 1, split_line_item)
        break
      else
        @discount_applicator.apply(line_item)
        num_to_discount -= line_item.quantity
      end
    end
  end
end

# ================================================================
# BuyVofWGetXofYForZCampaign
#
# Buy a certain number of matching items, get a certain number of
# a different set of matching items with the entered discount
# applied.
# ================================================================
class BuyVofWGetXofYForZCampaign
  def initialize(campaigns)
    @campaigns = campaigns
  end

  def run(cart)
    @campaigns.each do |campaign|
      buy_product_selector = ProductSelector.new(
        campaign[:buy_product_selector_match_type],
        campaign[:buy_product_selector_type],
        campaign[:buy_product_selectors],
      )

      get_product_selector = ProductSelector.new(
        campaign[:get_product_selector_match_type],
        campaign[:get_product_selector_type],
        campaign[:get_product_selectors],
      )

      buy_items = []
      get_items = []

      cart.line_items.each do |line_item|
        buy_items.push(line_item) if buy_product_selector.match?(line_item)
        get_items.push(line_item) if get_product_selector.match?(line_item)
      end

      next if buy_items.empty? || get_items.empty?

      get_items = get_items.sort_by { |line_item| line_item.variant.price }
      quantity_to_buy = campaign[:quantity_to_buy]
      quantity_to_discount = campaign[:quantity_to_discount]
      buy_offers = (buy_items.map(&:quantity).reduce(0, :+) / quantity_to_buy).floor

      if campaign[:allow_incomplete_bundle]
        number_of_bundles = buy_offers
      else
        get_offers = (get_items.map(&:quantity).reduce(0, :+) / quantity_to_discount).floor
        number_of_bundles = [buy_offers, get_offers].min
      end

      number_of_discountable_items = number_of_bundles * quantity_to_discount

      next unless number_of_discountable_items > 0

      discount_applicator = DiscountApplicator.new(
        campaign[:discount_type],
        campaign[:discount_amount],
        campaign[:discount_message]
      )

      discount_loop = DiscountLoop.new(discount_applicator)
      discount_loop.loop_items(cart, get_items, number_of_discountable_items)
    end
  end
end

CAMPAIGNS = [
  BuyVofWGetXofYForZCampaign.new(BUYVOFW_GETXOFY_FORZ),
]

CAMPAIGNS.each do |campaign|
  campaign.run(Input.cart)
end

Output.cart = Input.cart
