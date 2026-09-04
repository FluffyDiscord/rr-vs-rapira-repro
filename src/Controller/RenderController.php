<?php

declare(strict_types=1);

namespace App\Controller;

use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;
use Twig\Environment;

readonly class RenderController
{
    private const int ROW_COUNT = 200;

    public function __construct(
        private Environment $twig,
    ) {
    }

    #[Route(path: '/render', name: 'render', methods: ['GET'])]
    public function __invoke(): Response
    {
        $rows = range(1, self::ROW_COUNT);
        $html = $this->twig->render('render.html.twig', ['rows' => $rows]);

        return new Response($html);
    }
}
